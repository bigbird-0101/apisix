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

local ngx = ngx
local ngx_now = ngx.now
local ipairs = ipairs
local type = type
local math = math
local setmetatable = setmetatable
local string = string
local os = os

local _M = {
    host = "generativelanguage.googleapis.com",
    port = 443
}
local mt = { __index = _M }

local CONTENT_TYPE_JSON = "application/json"

local HTTP_INTERNAL_SERVER_ERROR = ngx.HTTP_INTERNAL_SERVER_ERROR
local HTTP_GATEWAY_TIMEOUT = ngx.HTTP_GATEWAY_TIMEOUT

function _M.new(opt)
    local self = setmetatable(opt or {}, mt)
    self.host = self.host or _M.host
    self.port = self.port or _M.port
    return self
end

local function handle_error(err)
    if core.string.find(err, "timeout") then
        return HTTP_GATEWAY_TIMEOUT
    end
    return HTTP_INTERNAL_SERVER_ERROR
end

local function build_proxy_opts(scheme)
    local http_proxy = os.getenv("HTTP_PROXY") or os.getenv("http_proxy")
    local https_proxy = os.getenv("HTTPS_PROXY") or os.getenv("https_proxy")
    local no_proxy = os.getenv("NO_PROXY") or os.getenv("no_proxy")
    core.log.info("build_proxy_opts using proxy - http: ", http_proxy or "none",
                  ", https: ", https_proxy or "none")
    if not http_proxy and not https_proxy then
        return nil
    end

    local proxy_opts = {}
    if http_proxy and http_proxy ~= "" then
        proxy_opts.http_proxy = http_proxy
    end
    if https_proxy and https_proxy ~= "" then
        proxy_opts.https_proxy = https_proxy
    end
    if no_proxy and no_proxy ~= "" then
        proxy_opts.no_proxy = no_proxy
    end

    core.log.info("using proxy - http: ", proxy_opts.http_proxy or "none",
                  ", https: ", proxy_opts.https_proxy or "none")
    return proxy_opts
end

local function normalize_gemini_usage(usage)
    if type(usage) ~= "table" then
        return nil
    end

    local prompt_tokens = usage.promptTokenCount or 0
    local completion_tokens = usage.candidatesTokenCount or 0

    return {
        prompt_tokens = prompt_tokens,
        completion_tokens = completion_tokens,
        total_tokens = usage.totalTokenCount or (prompt_tokens + completion_tokens),
    }
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

            local events = sse.decode(chunk)
            for _, event in ipairs(events) do
                local data = event.data
                if not data or data == "" then
                    goto CONTINUE
                end

                local json_data, decode_err = core.json.decode(data)
                if not json_data then
                    core.log.warn("failed to decode SSE data: ", decode_err)
                    goto CONTINUE
                end

                core.log.info("got token usage stream res_body: ", core.json.delay_encode(json_data))

                if json_data.usageMetadata then
                    ctx.llm_raw_usage = json_data.usageMetadata
                    local normalized = normalize_gemini_usage(json_data.usageMetadata)
                    if normalized then
                        ctx.ai_token_usage = normalized
                        ctx.var.llm_prompt_tokens = normalized.prompt_tokens
                        ctx.var.llm_completion_tokens = normalized.completion_tokens
                    end
                end

                ::CONTINUE::
            end
            plugin.lua_response_filter(ctx, res.headers, chunk)
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

    if res_body.usageMetadata then
        ctx.llm_raw_usage = res_body.usageMetadata
        local normalized = normalize_gemini_usage(res_body.usageMetadata)
        if normalized then
            ctx.ai_token_usage = normalized
            ctx.var.llm_prompt_tokens = normalized.prompt_tokens
            ctx.var.llm_completion_tokens = normalized.completion_tokens
        end
    end

    if type(res_body.candidates) == "table" and #res_body.candidates > 0 then
        local candidate = res_body.candidates[1]
        if type(candidate.content) == "table" and
           type(candidate.content.parts) == "table" then
            local text_parts = {}
            for _, part in ipairs(candidate.content.parts) do
                if part.text then
                    table.insert(text_parts, part.text)
                end
            end
            ctx.var.llm_response_text = table.concat(text_parts, "")
        end
    end

    plugin.lua_response_filter(ctx, res.headers, raw_res_body)
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
    local query_params = auth.query or {}
    if type(parsed_url) == "table" and parsed_url.query then
        local args_tab = core.string.decode_args(parsed_url.query)
        if type(args_tab) == "table" then
            core.table.merge(query_params, args_tab)
        end
    end

    local original_uri = ngx.var.request_uri or ""
    core.log.info("original request_uri: ", original_uri)
    
    if original_uri and string.find(original_uri, "alt=sse") then
        query_params.alt = "sse"
    end

    core.log.info("query_params after merge: ", core.json.delay_encode(query_params))

    local headers = auth.header or {}
    headers["Content-Type"] = "application/json"

    local api_key
    if auth.header and auth.header["Authorization"] then
        local auth_header = auth.header["Authorization"]
        if auth_header:match("^Bearer%s+(.+)$") then
            api_key = auth_header:match("^Bearer%s+(.+)$")
        end
    end

    if api_key then
        query_params.key = api_key
    end

    -- Resolve model: config > request body > URL path > default
    local model
    if extra_opts.model_options and extra_opts.model_options.model then
        model = extra_opts.model_options.model
    end
    if not model and request_table.model then
        model = request_table.model
        request_table.model = nil  -- Gemini native API doesn't use model in body
    end
    if not model and parsed_url and parsed_url.path then
        model = parsed_url.path:match("/models/([^/:]+)")
    end
    model = model or "gemini-pro"

    ctx.var.llm_model = model
    core.log.info("resolved gemini model: ", model)

    local path
    if parsed_url and parsed_url.path then
        path = parsed_url.path
    else
        local is_stream = request_table.stream or false
        if is_stream then
            path = "/v1beta/models/" .. model .. ":streamGenerateContent"
            query_params.alt = "sse"
        else
            path = "/v1beta/models/" .. model .. ":generateContent"
        end
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

    params.body = request_table

    local proxy_opts = build_proxy_opts(scheme)
    core.log.info("proxy_opts: ", core.json.delay_encode(proxy_opts, true))
    if proxy_opts then
        httpc:set_proxy_options(proxy_opts)
    end

    if self.request_filter then
        local code, err = self.request_filter(extra_opts.conf, ctx, params)
        if code then
            return code, err
        end
    end

    core.log.info("sending request to Gemini API: ", core.json.delay_encode(params, true))

    local ok, err = httpc:connect(params)
    if not ok then
        core.log.error("failed to connect to Gemini API: ", err)
        return handle_error(err)
    end

    local req_json, err = core.json.encode(params.body)
    if not req_json then
        return 500, "failed to encode request body: " .. (err or "unknown error")
    end

    params.body = req_json

    local res, err = httpc:request(params)
    if not res then
        core.log.warn("failed to send request to Gemini API: ", err)
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
