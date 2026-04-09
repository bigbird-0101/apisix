--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local _M = {}

local mt = {
    __index = _M
}

local CONTENT_TYPE_JSON = "application/json"

local core = require("apisix.core")
local plugin = require("apisix.plugin")
local http = require("resty.http")
local url  = require("socket.url")
local sse  = require("apisix.plugins.ai-drivers.sse")
local google_oauth = require("apisix.utils.google-cloud-oauth")

local lrucache = require("resty.lrucache")
local proxy_utils = require("apisix.plugins.ai-drivers.proxy-utils")
local ngx  = ngx
local ngx_now = ngx.now

local table = table
local pairs = pairs
local type  = type
local math  = math
local os    = os
local ipairs = ipairs
local setmetatable = setmetatable

local HTTP_INTERNAL_SERVER_ERROR = ngx.HTTP_INTERNAL_SERVER_ERROR
local HTTP_GATEWAY_TIMEOUT = ngx.HTTP_GATEWAY_TIMEOUT


function _M.new(opt)
    return setmetatable(opt, mt)
end


function _M.validate_request(ctx)
        local ct = core.request.header(ctx, "Content-Type") or CONTENT_TYPE_JSON
        if not core.string.has_prefix(ct, CONTENT_TYPE_JSON) then
            return nil, "unsupported content-type: " .. ct .. ", only application/json is supported"
        end

        local request_table, err = core.request.get_json_request_body_table()
        if not request_table then
            return nil, err
        end

        return request_table, nil
end


local function handle_error(err)
    if core.string.find(err, "timeout") then
        return HTTP_GATEWAY_TIMEOUT
    end
    return HTTP_INTERNAL_SERVER_ERROR
end


-- Normalize usage from different AI providers (OpenAI, Anthropic native, etc.)
-- OpenAI format: prompt_tokens, completion_tokens, total_tokens
-- Anthropic native format: input_tokens, output_tokens
local function normalize_usage(usage)
    if type(usage) ~= "table" then
        return nil
    end

    local prompt_tokens = usage.prompt_tokens or usage.input_tokens or 0
    local completion_tokens = usage.completion_tokens or usage.output_tokens or 0
    local total_tokens = usage.total_tokens or (prompt_tokens + completion_tokens)
    local prompt_token_details = usage.prompt_tokens_details
                                 or usage.input_tokens_details or {}
    local cached_prompt_tokens = prompt_token_details.cached_tokens or 0

    return {
        prompt_tokens = prompt_tokens,
        completion_tokens = completion_tokens,
        total_tokens = total_tokens,
        cached_prompt_tokens = cached_prompt_tokens,
        uncached_prompt_tokens = math.max(prompt_tokens - cached_prompt_tokens, 0),
    }
end

local build_proxy_opts = proxy_utils.build_proxy_opts

local function read_response(conf, ctx, res, response_filter)
    local body_reader = res.body_reader
    if not body_reader then
        core.log.warn("AI service sent no response body")
        return HTTP_INTERNAL_SERVER_ERROR
    end

    local content_type = res.headers["Content-Type"]
    core.response.set_header("Content-Type", content_type)
    core.log.info("got token usage from ai service content_type: ",content_type)
    if content_type and core.string.find(content_type, "text/event-stream") then
        local contents = {}
        while true do
            local chunk, err = body_reader() -- will read chunk by chunk
            ctx.var.apisix_upstream_response_time = math.floor((ngx_now() -
                                             ctx.llm_request_start_time) * 1000)
            if err then
                core.log.warn("failed to read response chunk: ", err)
                return handle_error(err)
            end
            if not chunk then
                return
            end

            if ctx.var.llm_time_to_first_token == "0" then
                ctx.var.llm_time_to_first_token = math.floor(
                                                (ngx_now() - ctx.llm_request_start_time) * 1000)
            end

            local events = sse.decode(chunk)
            ctx.llm_response_contents_in_chunk = {}
            for _, event in ipairs(events) do
                if event.type == "message" then
                    local data, err = core.json.decode(event.data)
                    if not data then
                        core.log.warn("failed to decode SSE data: ", err)
                        goto CONTINUE
                    end

                    if data and type(data.choices) == "table" and #data.choices > 0 then
                        for _, choice in ipairs(data.choices) do
                            if type(choice) == "table"
                                    and type(choice.delta) == "table"
                                    and type(choice.delta.content) == "string" then
                                core.table.insert(contents, choice.delta.content)
                                core.table.insert(ctx.llm_response_contents_in_chunk,
                                                        choice.delta.content)
                            end
                        end
                    end
                    core.log.info("got token usage stream res_body: ",core.json.delay_encode(data))
                    -- usage field is null for non-last events, null is parsed as userdata type
                    if data and type(data.usage) == "table" then
                        core.log.info("got token usage from ai service: ",
                                            core.json.delay_encode(data.usage))
                        ctx.llm_raw_usage = data.usage
                        local normalized = normalize_usage(data.usage)
                        if normalized then
                            ctx.ai_token_usage = normalized
                            ctx.var.llm_prompt_tokens = normalized.prompt_tokens
                            ctx.var.llm_completion_tokens = normalized.completion_tokens
                        end
                        ctx.var.llm_response_text = table.concat(contents, "")
                    end
                elseif event.type == "done" then
                    ctx.var.llm_request_done = true
                end

                ::CONTINUE::
            end

            plugin.lua_response_filter(ctx, res.headers, chunk)
        end
    end

    local headers = res.headers
    local raw_res_body, err = res:read_body()
    if not raw_res_body then
        core.log.warn("failed to read response body: ", err)
        return handle_error(err)
    end
    ngx.status = res.status
    ctx.var.llm_time_to_first_token = math.floor((ngx_now() - ctx.llm_request_start_time) * 1000)
    ctx.var.apisix_upstream_response_time = ctx.var.llm_time_to_first_token
    local res_body, err = core.json.decode(raw_res_body)
    core.log.info("got token usage res_body: ",res_body)
    if err then
        core.log.warn("invalid response body from ai service: ", raw_res_body, " err: ", err,
            ", it will cause token usage not available")
    else
        if response_filter then
            local resp = {
                headers = headers,
                body = res_body,
            }
            local code, err = response_filter(conf, ctx, resp)
            if code then
                return code, err
            end
            if resp.body then
                local body, err = core.json.encode(resp.body)
                if not body then
                    core.log.error("failed to encode response body after response filter: ", err)
                    return 500
                end
                raw_res_body = body
            end
            headers = resp.headers
        end
        core.log.info("got token usage from ai service: ", core.json.delay_encode(res_body.usage))
        ctx.ai_token_usage = {}
        if type(res_body.usage) == "table" then
            ctx.llm_raw_usage = res_body.usage
            local normalized = normalize_usage(res_body.usage)
            if normalized then
                ctx.ai_token_usage = normalized
            end
        end
        ctx.var.llm_prompt_tokens = ctx.ai_token_usage.prompt_tokens or 0
        ctx.var.llm_completion_tokens = ctx.ai_token_usage.completion_tokens or 0
        if type(res_body.choices) == "table" and #res_body.choices > 0 then
            local contents = {}
            for _, choice in ipairs(res_body.choices) do
                if type(choice) == "table"
                        and type(choice.message) == "table"
                        and type(choice.message.content) == "string" then
                    core.table.insert(contents, choice.message.content)
                end
            end
            local content_to_check = table.concat(contents, " ")
            ctx.var.llm_response_text = content_to_check
        end
    end
    plugin.lua_response_filter(ctx, headers, raw_res_body)
end


local gcp_access_token_cache = lrucache.new(1024 * 4)

local function fetch_gcp_access_token(ctx, name, gcp_conf)
    local key = core.lrucache.plugin_ctx_id(ctx, name)
    local access_token = gcp_access_token_cache:get(key)
    if access_token then
        return access_token
    end
    -- generate access token
    local auth_conf = {}
    local service_account_json = gcp_conf.service_account_json or
                                    os.getenv("GCP_SERVICE_ACCOUNT")
    core.log.info("gcp auth: service_account_json from config: ",
                  gcp_conf.service_account_json and "yes" or "no",
                  ", from env: ", os.getenv("GCP_SERVICE_ACCOUNT") and "yes" or "no")
    if type(service_account_json) == "string" and service_account_json ~= "" then
        local conf, err = core.json.decode(service_account_json)
        if not conf then
            return nil, "invalid gcp service account json: " .. (err or "unknown error")
        end
        auth_conf = conf
    else
        return nil, "no GCP service account found in config or GCP_SERVICE_ACCOUNT env var"
    end
    local oauth = google_oauth.new(auth_conf)
    access_token = oauth:generate_access_token()
    if not access_token then
        return nil, "failed to get google oauth token"
    end
    local ttl = oauth.access_token_ttl or 6
    if gcp_conf.expire_early_secs and ttl > gcp_conf.expire_early_secs then
        ttl = ttl - gcp_conf.expire_early_secs
    end
    if gcp_conf.max_ttl and ttl > gcp_conf.max_ttl then
        ttl = gcp_conf.max_ttl
    end
    gcp_access_token_cache:set(key, access_token, ttl)
    core.log.debug("set gcp access token in cache with ttl: ", ttl, ", key: ", key)
    return access_token
end


function _M.request(self, ctx, conf, request_table, extra_opts)
    local httpc, err = http.new()
    if not httpc then
        core.log.error("failed to create http client to send request to LLM server: ", err)
        return HTTP_INTERNAL_SERVER_ERROR
    end
    httpc:set_timeout(conf.timeout)

    core.log.info("request extra_opts to LLM server: ", core.json.delay_encode(extra_opts, true))

    local auth = extra_opts.auth or {}
    local token
    if auth.gcp then
        local access_token, err = fetch_gcp_access_token(ctx, extra_opts.name,
                                        auth.gcp)
        if not access_token then
            core.log.error("failed to get gcp access token: ", err)
            return 500
        end
        token = access_token
    end

    local endpoint = extra_opts.endpoint
    local parsed_url
    if endpoint then
        parsed_url = url.parse(endpoint)
    end

    -- For providers with dynamic host (e.g., vertex-ai), call get_node
    local default_scheme = "https"
    local default_host = self.host
    local default_port = self.port
    if self.get_node and not endpoint then
        local node = self.get_node(ctx.picked_ai_instance or extra_opts)
        if node then
            default_scheme = node.scheme or "https"
            default_host = node.host
            default_port = node.port
        end
    end

    local scheme = parsed_url and parsed_url.scheme or default_scheme
    local host = parsed_url and parsed_url.host or default_host
    local port = parsed_url and parsed_url.port or default_port
    if not port then
        if scheme == "https" then
            port = 443
        else
            port = 80
        end
    end

    local query_params = auth.query or {}

    if type(parsed_url) == "table" and parsed_url.query and #parsed_url.query > 0 then
        local args_tab = core.string.decode_args(parsed_url.query)
        if type(args_tab) == "table" then
            core.table.merge(query_params, args_tab)
        end
    end

    local path = (parsed_url and parsed_url.path or self.path)

    local headers = auth.header or {}
    headers["Content-Type"] = "application/json"
    if token then
        headers["Authorization"] = "Bearer " .. token
    end

    -- Set proxy options from environment variables (must be set before connect)
    local proxy_opts = build_proxy_opts(scheme)
    core.log.info("proxy_opts: ", core.json.delay_encode(proxy_opts, true))
    if proxy_opts then
        httpc:set_proxy_options(proxy_opts)
    end

    local params = {
        method = "POST",
        scheme = scheme,
        headers = headers,
        ssl_verify = conf.ssl_verify,
        path = path,
        query = query_params,
        host = host,
        port = port,
        ssl_server_name = parsed_url and parsed_url.host or self.host,
    }

    if extra_opts.model_options then
        for opt, val in pairs(extra_opts.model_options) do
            request_table[opt] = val
        end
    end
    params.body = request_table

    if self.remove_model then
        request_table.model = nil
    end

    if self.request_filter then
        local code, err = self.request_filter(extra_opts.conf, ctx, params)
        if code then
            return code, err
        end
    end

    core.log.info("sending request to LLM server: ", core.json.delay_encode(params, true))

    local ok, err = httpc:connect(params)
    if not ok then
        core.log.error("failed to connect to LLM server: ", err)
        return handle_error(err)
    end

    local req_json, err = core.json.encode(params.body)
    if not req_json then
        return 500, "failed to encode request body: " .. (err or "unknown error")
    end

    params.body = req_json

    local res, err = httpc:request(params)
    if not res then
        core.log.warn("failed to send request to LLM server: ", err)
        return handle_error(err)
    end

    -- handling this error separately is needed for retries
    if res.status == 429 or (res.status >= 500 and res.status < 600 )then
        return res.status
    end

    local code, body = read_response(extra_opts.conf, ctx, res, self.response_filter)

    if conf.keepalive then
        local ok, err = httpc:set_keepalive(conf.keepalive_timeout, conf.keepalive_pool)
        if not ok then
            core.log.warn("failed to keepalive connection: ", err)
        end
    end

    return code, body
end


return _M
