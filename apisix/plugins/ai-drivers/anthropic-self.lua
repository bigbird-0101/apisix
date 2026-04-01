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

local core = require("apisix.core")
local http = require("resty.http")
local sse  = require("apisix.plugins.ai-drivers.sse")
local plugin = require("apisix.plugin")
local url  = require("socket.url")
local google_oauth = require("apisix.utils.google-cloud-oauth")
local lrucache = require("resty.lrucache")
local proxy_utils = require("apisix.plugins.ai-drivers.proxy-utils")

local ngx = ngx
local ngx_now = ngx.now
local ipairs = ipairs
local type = type
local table = table
local math = math
local setmetatable = setmetatable
local string = string
local os = os

local _M = {}
local mt = { __index = _M }

local CONTENT_TYPE_JSON = "application/json"
local ANTHROPIC_VERSION = "2023-06-01"

local HTTP_INTERNAL_SERVER_ERROR = ngx.HTTP_INTERNAL_SERVER_ERROR
local HTTP_GATEWAY_TIMEOUT = ngx.HTTP_GATEWAY_TIMEOUT

function _M.new(opt)
    local self = setmetatable(opt or {}, mt)
    self.host = self.host or "api.anthropic.com"
    self.path = self.path or "/v1/messages"
    self.port = self.port or 443
    return self
end

local function handle_error(err)
    if core.string.find(err, "timeout") then
        return HTTP_GATEWAY_TIMEOUT
    end
    return HTTP_INTERNAL_SERVER_ERROR
end

local build_proxy_opts = proxy_utils.build_proxy_opts

local function get_anthropic_input_tokens(usage)
    if type(usage) ~= "table" then
        return 0
    end

    return (usage.input_tokens or 0)
        + (usage.cache_creation_input_tokens or 0)
        + (usage.cache_read_input_tokens or 0)
end

local function normalize_usage(usage)
    if type(usage) ~= "table" then
        return nil
    end

    local input_tokens = get_anthropic_input_tokens(usage)
    local output_tokens = usage.output_tokens or 0
    local cache_creation = usage.cache_creation or {}

    return {
        prompt_tokens = input_tokens,
        completion_tokens = output_tokens,
        total_tokens = input_tokens + output_tokens,
        uncached_prompt_tokens = usage.input_tokens or 0,
        cache_creation_prompt_tokens = usage.cache_creation_input_tokens or 0,
        cache_creation_5m_prompt_tokens = cache_creation.ephemeral_5m_input_tokens or 0,
        cache_creation_1h_prompt_tokens = cache_creation.ephemeral_1h_input_tokens or 0,
        cache_read_prompt_tokens = usage.cache_read_input_tokens or 0,
    }
end


local function merge_anthropic_usage(existing, incoming)
    if type(existing) ~= "table" then
        existing = {}
    end

    if type(incoming) ~= "table" then
        return existing
    end

    local merged = core.table.clone(existing) or {}
    for key, value in pairs(incoming) do
        if type(value) == "table" and type(merged[key]) == "table" then
            local nested = core.table.clone(merged[key]) or {}
            for nested_key, nested_value in pairs(value) do
                nested[nested_key] = nested_value
            end
            merged[key] = nested
        else
            merged[key] = value
        end
    end

    return merged
end


local function apply_usage_to_ctx(ctx, usage)
    if type(usage) ~= "table" then
        return
    end

    ctx.llm_raw_usage = usage
    local normalized = normalize_usage(usage)
    if normalized then
        ctx.ai_token_usage = normalized
        ctx.var.llm_prompt_tokens = normalized.prompt_tokens or 0
        ctx.var.llm_completion_tokens = normalized.completion_tokens or 0
    end
end

local function transform_openai_to_anthropic(request_table)
    local anthropic_request = {
        model = request_table.model,
        max_tokens = request_table.max_tokens or 4096,
        stream = request_table.stream or false,
    }

    if request_table.temperature then
        anthropic_request.temperature = request_table.temperature
    end
    if request_table.top_p then
        anthropic_request.top_p = request_table.top_p
    end
    if request_table.top_k then
        anthropic_request.top_k = request_table.top_k
    end
    if request_table.stop then
        anthropic_request.stop_sequences = type(request_table.stop) == "table"
            and request_table.stop or { request_table.stop }
    end

    local messages = {}
    local system_content = nil

    if type(request_table.messages) == "table" then
        for _, msg in ipairs(request_table.messages) do
            if msg.role == "system" then
                system_content = msg.content
            else
                local anthropic_msg = {
                    role = msg.role,
                    content = msg.content
                }
                table.insert(messages, anthropic_msg)
            end
        end
    end

    if system_content then
        anthropic_request.system = system_content
    end
    anthropic_request.messages = messages

    return anthropic_request
end

local function transform_anthropic_to_openai(response_body)
    local openai_response = {
        id = response_body.id,
        object = "chat.completion",
        created = ngx.time(),
        model = response_body.model,
        choices = {},
        usage = nil
    }

    if type(response_body.content) == "table" and #response_body.content > 0 then
        local text_content = ""
        for _, block in ipairs(response_body.content) do
            if block.type == "text" then
                text_content = text_content .. (block.text or "")
            end
        end

        openai_response.choices = {
            {
                index = 0,
                message = {
                    role = "assistant",
                    content = text_content
                },
                finish_reason = response_body.stop_reason or "stop"
            }
        }
    end

    if response_body.usage then
        local prompt_tokens = get_anthropic_input_tokens(response_body.usage)
        local completion_tokens = response_body.usage.output_tokens or 0
        openai_response.usage = {
            prompt_tokens = prompt_tokens,
            completion_tokens = completion_tokens,
            total_tokens = prompt_tokens + completion_tokens
        }
    end

    return openai_response
end

local function read_response(conf, ctx, res)
    local body_reader = res.body_reader
    if not body_reader then
        core.log.warn("AI service sent no response body")
        return HTTP_INTERNAL_SERVER_ERROR
    end

    local content_type = res.headers["Content-Type"]
    core.response.set_header("Content-Type", content_type)
    core.log.info("got token usage from ai service content_type: ", content_type)

    if content_type and core.string.find(content_type, "text/event-stream") then
        local contents = {}
        while true do
            local chunk, err = body_reader()
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


            ctx.llm_response_contents_in_chunk = {}
            local events = sse.decode(chunk)
            for _, event in ipairs(events) do
                local data = event.data
                if data and data ~= "" then
                    local json_data, decode_err = core.json.decode(data)
                    if not json_data then
                        core.log.warn("failed to decode SSE data: ", decode_err)
                    else
                        local event_type = json_data.type or event.type

                        if event_type == "message_start" then
                            if json_data.message and json_data.message.usage then
                                core.log.info("got token usage from ai service: ",
                                                    core.json.delay_encode(json_data.message.usage))
                                apply_usage_to_ctx(ctx, json_data.message.usage)
                            end
                        elseif event_type == "content_block_delta" then
                            if json_data.delta and json_data.delta.type == "text_delta" then
                                local text = json_data.delta.text or ""
                                table.insert(contents, text)
                                table.insert(ctx.llm_response_contents_in_chunk, text)
                                ctx.var.llm_response_text = table.concat(contents, "")
                            end
                        elseif event_type == "message_delta" then
                            if json_data.usage then
                                local merged_usage = merge_anthropic_usage(ctx.llm_raw_usage,
                                    json_data.usage)
                                core.log.info("got final token usage from ai service: ",
                                    core.json.delay_encode(merged_usage))
                                apply_usage_to_ctx(ctx, merged_usage)
                            end
                        elseif event_type == "message_stop" then
                            ctx.var.llm_request_done = true
                            ctx.var.llm_response_text = table.concat(contents, "")
                        end
                    end
                end
            end
            plugin.lua_response_filter(ctx, res.headers, chunk)
            -- local response_chunks = {}
            -- local events = sse.decode(chunk)
            -- for _, event in ipairs(events) do
            --     local data = event.data
            --     if not data or data == "" then
            --         goto CONTINUE
            --     end

            --     local json_data, decode_err = core.json.decode(data)
            --     if not json_data then
            --         core.log.warn("failed to decode SSE data: ", decode_err)
            --         goto CONTINUE
            --     end

            --     local event_type = json_data.type or event.type

            --     if event_type == "content_block_delta" then
            --         if json_data.delta and json_data.delta.type == "text_delta" then
            --             local text = json_data.delta.text or ""
            --             core.table.insert(contents, text)
            --             core.table.insert(ctx.llm_response_contents_in_chunk, text)

            --             local openai_chunk = {
            --                 id = json_data.id or "chatcmpl-anthropic",
            --                 object = "chat.completion.chunk",
            --                 created = ngx.time(),
            --                 model = ctx.var.llm_model or "",
            --                 choices = {
            --                     {
            --                         index = 0,
            --                         delta = {
            --                             content = text
            --                         },
            --                         finish_reason = nil
            --                     }
            --                 }
            --             }
            --             local chunk_json = core.json.encode(openai_chunk)
            --             core.table.insert(response_chunks, "data: " .. chunk_json .. "\n\n")
            --         end
            --     elseif event_type == "message_delta" then
            --         if json_data.usage then
            --             core.log.info("got token usage from ai service: ",
            --                                 core.json.delay_encode(json_data.usage))
            --             ctx.llm_raw_usage = json_data.usage
            --             local normalized = normalize_usage(json_data.usage)
            --             if normalized then
            --                 ctx.ai_token_usage = normalized
            --                 ctx.var.llm_prompt_tokens = normalized.prompt_tokens
            --                 ctx.var.llm_completion_tokens = normalized.completion_tokens
            --             end
            --         end
            --     elseif event_type == "message_start" then
            --         if json_data.message and json_data.message.usage then
            --             ctx.llm_raw_usage = json_data.message.usage
            --             local normalized = normalize_usage(json_data.message.usage)
            --             if normalized then
            --                 ctx.ai_token_usage = normalized
            --                 ctx.var.llm_prompt_tokens = normalized.prompt_tokens
            --                 ctx.var.llm_completion_tokens = normalized.completion_tokens or 0
            --             end
            --         end
            --     elseif event_type == "message_stop" then
            --         core.table.insert(response_chunks, "data: [DONE]\n\n")
            --         ctx.var.llm_request_done = true
            --         ctx.var.llm_response_text = table.concat(contents, "")
            --     end

            --     ::CONTINUE::
            -- end

            -- local response_data = table.concat(response_chunks, "")
            -- if response_data ~= "" then
            --     plugin.lua_response_filter(ctx, res.headers, response_data)
            -- end
        end
    end

    local raw_res_body, err = res:read_body()
    if not raw_res_body then
        core.log.warn("failed to read response body: ", err)
        return handle_error(err)
    end

    ngx.status = res.status
    ctx.var.llm_time_to_first_token = math.floor((ngx_now() - ctx.llm_request_start_time) * 1000)
    ctx.var.apisix_upstream_response_time = ctx.var.llm_time_to_first_token

    local res_body, err = core.json.decode(raw_res_body)
    core.log.info("got token usage from ai service res_body: ", core.json.delay_encode(res_body))
    if err then
        core.log.warn("invalid response body from ai service: ", raw_res_body, " err: ", err,
            ", it will cause token usage not available")
        plugin.lua_response_filter(ctx, res.headers, raw_res_body)
        return
    end

    if res_body.usage then
        apply_usage_to_ctx(ctx, res_body.usage)
    end

    local openai_response = transform_anthropic_to_openai(res_body)

    if openai_response.choices and #openai_response.choices > 0 then
        ctx.var.llm_response_text = openai_response.choices[1].message.content or ""
    end

    local response_json, err = core.json.encode(openai_response)
    if not response_json then
        core.log.error("failed to encode response: ", err)
        return HTTP_INTERNAL_SERVER_ERROR
    end

    plugin.lua_response_filter(ctx, res.headers, response_json)
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
    if type(service_account_json) == "string" and service_account_json ~= "" then
        local conf, err = core.json.decode(service_account_json)
        if not conf then
            return nil, "invalid gcp service account json: " .. (err or "unknown error")
        end
        auth_conf = conf
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
        core.log.error("failed to create http client: ", err)
        return HTTP_INTERNAL_SERVER_ERROR
    end
    httpc:set_timeout(conf.timeout)
    local endpoint = extra_opts.endpoint
    local parsed_url
    if endpoint then
        parsed_url = url.parse(endpoint)
    end

    local scheme = parsed_url and parsed_url.scheme or "https"
    local host = parsed_url and parsed_url.host or self.host
    local port = parsed_url and parsed_url.port
    if not port then
        if scheme == "https" then
            port = 443
        else
            port = 80
        end
    end

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

    local proxy_opts = build_proxy_opts(scheme)
    core.log.info("proxy_opts: ", core.json.delay_encode(proxy_opts, true))
    if proxy_opts then
        httpc:set_proxy_options(proxy_opts)
    end

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
        core.log.error("failed to connect to Anthropic API: ", err)
        return handle_error(err)
    end

    local req_json, err = core.json.encode(params.body)
    if not req_json then
        return 500, "failed to encode request body: " .. (err or "unknown error")
    end

    params.body = req_json

    local res, err = httpc:request(params)
    if not res then
        core.log.warn("failed to send request to Anthropic API: ", err)
        return handle_error(err)
    end

    if res.status == 429 or (res.status >= 500 and res.status < 600) then
        return res.status
    end

    local code, body = read_response(conf, ctx, res)

    if conf.keepalive then
        local ok, err = httpc:set_keepalive(conf.keepalive_timeout, conf.keepalive_pool)
        if not ok then
            core.log.warn("failed to keepalive connection: ", err)
        end
    end

    return code, body
end

return _M
