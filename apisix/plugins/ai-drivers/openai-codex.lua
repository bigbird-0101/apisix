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
local lrucache = require("resty.lrucache")

local ngx = ngx
local ngx_now = ngx.now
local ipairs = ipairs
local type = type
local math = math
local setmetatable = setmetatable
local os = os

local _M = {}
local mt = { __index = _M }

local CONTENT_TYPE_JSON = "application/json"

local HTTP_INTERNAL_SERVER_ERROR = ngx.HTTP_INTERNAL_SERVER_ERROR
local HTTP_GATEWAY_TIMEOUT = ngx.HTTP_GATEWAY_TIMEOUT

-- OAuth token refresh endpoint
local OPENAI_TOKEN_ENDPOINT = "https://auth.openai.com/oauth/token"

-- Cache refreshed tokens (survives across requests within worker)
local oauth_token_cache = lrucache.new(256)


function _M.new(opt)
    local self = setmetatable(opt or {}, mt)
    self.host = self.host or "chatgpt.com"
    self.path = self.path or "/backend-api/responses"
    self.port = self.port or 443
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
    return proxy_opts
end


local function normalize_usage(usage)
    if type(usage) ~= "table" then
        return nil
    end

    local input_tokens = usage.input_tokens
                         or usage.prompt_tokens or 0
    local output_tokens = usage.output_tokens
                          or usage.completion_tokens or 0

    return {
        prompt_tokens = input_tokens,
        completion_tokens = output_tokens,
        total_tokens = input_tokens + output_tokens,
    }
end


--- Refresh OAuth access token using refresh_token
--- @param oauth_conf table  {access_token, refresh_token, expires, account_id, client_id}
--- @return string|nil access_token
--- @return string|nil error
local function refresh_oauth_token(oauth_conf)
    local cache_key = "oauth#" .. (oauth_conf.refresh_token or ""):sub(1, 32)

    -- Check cache first
    local cached = oauth_token_cache:get(cache_key)
    if cached and cached.expires > ngx_now() * 1000 then
        core.log.info("using cached oauth token, expires in: ",
                      math.floor((cached.expires - ngx_now() * 1000) / 1000), "s")
        return cached.access_token
    end

    -- Check if current token is still valid
    if oauth_conf.expires and oauth_conf.expires > ngx_now() * 1000 then
        oauth_token_cache:set(cache_key, {
            access_token = oauth_conf.access_token,
            expires = oauth_conf.expires,
        }, math.floor((oauth_conf.expires - ngx_now() * 1000) / 1000))
        return oauth_conf.access_token
    end

    core.log.info("oauth token expired, refreshing...")

    local httpc, err = http.new()
    if not httpc then
        core.log.error("failed to create http client for token refresh: ", err)
        -- Fallback to cached access token
        return oauth_conf.access_token
    end
    httpc:set_timeout(10000)

    local ok, err = httpc:connect({
        scheme = "https",
        host = "auth.openai.com",
        port = 443,
        ssl_verify = true,
        ssl_server_name = "auth.openai.com",
    })
    if not ok then
        core.log.error("failed to connect to OpenAI auth server: ", err)
        return oauth_conf.access_token
    end

    local body = "grant_type=refresh_token"
                 .. "&refresh_token=" .. ngx.escape_uri(oauth_conf.refresh_token)
    if oauth_conf.client_id then
        body = body .. "&client_id=" .. ngx.escape_uri(oauth_conf.client_id)
    end

    local res, err = httpc:request({
        method = "POST",
        path = "/oauth/token",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Accept"] = "application/json",
        },
        body = body,
    })

    if not res then
        core.log.error("failed to request token refresh: ", err)
        return oauth_conf.access_token
    end

    local res_body, err = res:read_body()
    if not res_body then
        core.log.error("failed to read token refresh response: ", err)
        return oauth_conf.access_token
    end

    if res.status ~= 200 then
        core.log.error("token refresh failed with status ", res.status, ": ", res_body)
        -- Fallback: use the existing access token even if expired
        core.log.warn("using cached access token as fallback")
        return oauth_conf.access_token
    end

    local token_data, err = core.json.decode(res_body)
    if not token_data then
        core.log.error("failed to decode token refresh response: ", err)
        return oauth_conf.access_token
    end

    local new_access = token_data.access_token
    if not new_access then
        core.log.error("no access_token in refresh response")
        return oauth_conf.access_token
    end

    local expires_in = token_data.expires_in or 3600
    local new_expires = ngx_now() * 1000 + expires_in * 1000

    -- Cache the new token
    oauth_token_cache:set(cache_key, {
        access_token = new_access,
        expires = new_expires,
    }, expires_in - 60) -- expire cache slightly before actual expiry

    core.log.info("oauth token refreshed successfully, expires_in: ", expires_in, "s")

    httpc:set_keepalive(60000, 5)

    return new_access
end


--- Resolve the access token from auth config
--- Supports both oauth and header-based auth
local function resolve_access_token(auth)
    if not auth then
        return nil, "no auth config"
    end

    -- OAuth mode
    if auth.oauth then
        local oauth_conf = auth.oauth
        if not oauth_conf.access_token then
            return nil, "missing oauth access_token"
        end
        return refresh_oauth_token(oauth_conf)
    end

    -- Header mode (fallback)
    if auth.header and auth.header["Authorization"] then
        local auth_header = auth.header["Authorization"]
        if core.string.has_prefix(auth_header, "Bearer ") then
            return auth_header:sub(8)
        end
        return auth_header
    end

    return nil, "no supported auth method found"
end


local function read_response(conf, ctx, res)
    local body_reader = res.body_reader
    if not body_reader then
        core.log.warn("AI service sent no response body")
        return HTTP_INTERNAL_SERVER_ERROR
    end

    local content_type = res.headers["Content-Type"]
    core.response.set_header("Content-Type", content_type)

    -- Streaming response (SSE)
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

            -- Try to parse usage from SSE events
            local events = sse.decode(chunk)
            for _, event in ipairs(events) do
                local data = event.data
                if not data or data == "" then
                    goto CONTINUE
                end

                local json_data, decode_err = core.json.decode(data)
                if not json_data then
                    goto CONTINUE
                end

                -- Extract token usage from response events
                if json_data.usage then
                    local normalized = normalize_usage(json_data.usage)
                    if normalized then
                        ctx.ai_token_usage = normalized
                        ctx.var.llm_prompt_tokens = normalized.prompt_tokens or 0
                        ctx.var.llm_completion_tokens = normalized.completion_tokens or 0
                    end
                end

                ::CONTINUE::
            end

            plugin.lua_response_filter(ctx, res.headers, chunk)
        end
    end

    -- Non-streaming response
    local raw_res_body, err = res:read_body()
    if not raw_res_body then
        core.log.warn("failed to read response body: ", err)
        return handle_error(err)
    end

    ngx.status = res.status
    ctx.var.llm_time_to_first_token = math.floor((ngx_now() - ctx.llm_request_start_time) * 1000)
    ctx.var.apisix_upstream_response_time = ctx.var.llm_time_to_first_token

    local res_body, err = core.json.decode(raw_res_body)
    if err then
        core.log.warn("invalid response body from ai service: ", raw_res_body)
        plugin.lua_response_filter(ctx, res.headers, raw_res_body)
        return
    end

    if res_body.usage then
        local normalized = normalize_usage(res_body.usage)
        if normalized then
            ctx.ai_token_usage = normalized
            ctx.var.llm_prompt_tokens = normalized.prompt_tokens
            ctx.var.llm_completion_tokens = normalized.completion_tokens
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
        port = scheme == "https" and 443 or 80
    end

    -- Resolve OAuth access token
    local auth = extra_opts.auth or {}
    local access_token, err = resolve_access_token(auth)
    if not access_token then
        core.log.error("failed to resolve access token: ", err)
        return 401, "unauthorized: " .. (err or "no token")
    end

    local headers = {}
    -- Copy extra headers from auth.header (excluding Authorization which we handle)
    if auth.header then
        for k, v in pairs(auth.header) do
            if k ~= "Authorization" then
                headers[k] = v
            end
        end
    end

    headers["Content-Type"] = "application/json"
    headers["Authorization"] = "Bearer " .. access_token

    -- Add ChatGPT-Account-Id if configured
    if auth.oauth and auth.oauth.account_id then
        headers["ChatGPT-Account-Id"] = auth.oauth.account_id
    end

    local query_params = auth.query or {}
    if type(parsed_url) == "table" and parsed_url.query and #parsed_url.query > 0 then
        local args_tab = core.string.decode_args(parsed_url.query)
        if type(args_tab) == "table" then
            core.table.merge(query_params, args_tab)
        end
    end

    local path = parsed_url and parsed_url.path or self.path

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

    local proxy_opts = build_proxy_opts(scheme)
    if proxy_opts then
        httpc:set_proxy_options(proxy_opts)
    end

    if self.request_filter then
        local code, err = self.request_filter(extra_opts.conf, ctx, params)
        if code then
            return code, err
        end
    end

    core.log.info("sending request to OpenAI Codex: ", host, path)

    local ok, err = httpc:connect(params)
    if not ok then
        core.log.error("failed to connect to OpenAI Codex API: ", err)
        return handle_error(err)
    end

    local req_json, err = core.json.encode(request_table)
    if not req_json then
        return 500, "failed to encode request body: " .. (err or "unknown error")
    end

    params.body = req_json

    local res, err = httpc:request(params)
    if not res then
        core.log.warn("failed to send request to OpenAI Codex API: ", err)
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
