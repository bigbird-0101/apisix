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
local proxy_utils = require("apisix.plugins.ai-drivers.proxy-utils")

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


local build_proxy_opts = proxy_utils.build_proxy_opts


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


--- Decode JWT payload (no signature verification, just parse claims)
local function decode_jwt_payload(token)
    if not token then
        return nil
    end

    -- JWT format: header.payload.signature
    local dot1 = token:find(".", 1, true)
    if not dot1 then
        return nil
    end
    local dot2 = token:find(".", dot1 + 1, true)
    if not dot2 then
        return nil
    end

    local payload_b64 = token:sub(dot1 + 1, dot2 - 1)
    -- Fix base64url padding
    local padding = (4 - #payload_b64 % 4) % 4
    payload_b64 = payload_b64 .. ("="):rep(padding)
    -- base64url -> base64
    payload_b64 = payload_b64:gsub("-", "+"):gsub("_", "/")

    local payload_json = ngx.decode_base64(payload_b64)
    if not payload_json then
        return nil
    end

    return core.json.decode(payload_json)
end


--- Extract client_id and account_id from JWT access token
local function extract_token_claims(oauth_conf)
    local claims = decode_jwt_payload(oauth_conf.access_token)
    if not claims then
        return
    end

    if not oauth_conf.client_id and claims.client_id then
        oauth_conf.client_id = claims.client_id
        core.log.info("auto-extracted client_id from JWT: ", claims.client_id)
    end

    if not oauth_conf.account_id then
        local auth_info = claims["https://api.openai.com/auth"]
        if auth_info and auth_info.chatgpt_account_id then
            oauth_conf.account_id = auth_info.chatgpt_account_id
            core.log.info("auto-extracted account_id from JWT: ", auth_info.chatgpt_account_id)
        end
    end
end


-- Stable cache key based on the original refresh_token from config
-- (doesn't change even after token rotation)
local OAUTH_CACHE_KEY = "openai_codex_oauth"


--- Get token expiry from JWT exp claim (seconds -> milliseconds)
local function get_token_expiry_ms(access_token)
    local claims = decode_jwt_payload(access_token)
    if claims and claims.exp then
        return claims.exp * 1000
    end
    return nil
end


--- Refresh OAuth access token using refresh_token
--- Handles OpenAI's single-use refresh token rotation:
---   - On success, stores new access_token AND new refresh_token in cache
---   - On failure (token reused), falls back to cached access_token
--- @param oauth_conf table  {access_token, refresh_token, expires, account_id, client_id}
--- @return string|nil access_token
local function refresh_oauth_token(oauth_conf)
    -- Auto-extract client_id and account_id from JWT if not configured
    extract_token_claims(oauth_conf)

    -- Check cache first (may contain rotated tokens from a previous refresh)
    local cached = oauth_token_cache:get(OAUTH_CACHE_KEY)
    if cached then
        local now_ms = ngx_now() * 1000
        if cached.expires and cached.expires > now_ms then
            core.log.info("using cached oauth token, expires in: ",
                          math.floor((cached.expires - now_ms) / 1000), "s")
            return cached.access_token
        end
        -- Cached token expired, use cached refresh_token for next refresh
        -- (it may be a rotated one from a previous successful refresh)
        if cached.refresh_token then
            core.log.info("cached access token expired, will use cached refresh_token")
            oauth_conf = core.table.clone(oauth_conf)
            oauth_conf.refresh_token = cached.refresh_token
        end
    end

    -- Check if the config token is still valid (first time, before any cache)
    if not cached then
        local expires = oauth_conf.expires or get_token_expiry_ms(oauth_conf.access_token)
        if expires and expires > ngx_now() * 1000 then
            local ttl = math.floor((expires - ngx_now() * 1000) / 1000)
            oauth_token_cache:set(OAUTH_CACHE_KEY, {
                access_token = oauth_conf.access_token,
                refresh_token = oauth_conf.refresh_token,
                expires = expires,
            }, ttl)
            return oauth_conf.access_token
        end
    end

    core.log.info("oauth token expired, refreshing with refresh_token: ",
                  (oauth_conf.refresh_token or ""):sub(1, 20), "...")

    local httpc, err = http.new()
    if not httpc then
        core.log.error("failed to create http client for token refresh: ", err)
        return oauth_conf.access_token
    end
    httpc:set_timeout(10000)

    -- Use proxy if configured
    local proxy_opts = build_proxy_opts("https")
    if proxy_opts then
        httpc:set_proxy_options(proxy_opts)
    end

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
        core.log.warn("using cached access token as fallback")
        -- Return whatever access token we have (cached or original)
        if cached and cached.access_token then
            return cached.access_token
        end
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

    -- OpenAI uses refresh token rotation: new refresh_token is returned
    local new_refresh = token_data.refresh_token or oauth_conf.refresh_token
    local expires_in = token_data.expires_in or 3600
    local new_expires = ngx_now() * 1000 + expires_in * 1000

    -- Also extract account_id from the new JWT
    local new_claims = decode_jwt_payload(new_access)
    if new_claims then
        local auth_info = new_claims["https://api.openai.com/auth"]
        if auth_info and auth_info.chatgpt_account_id then
            oauth_conf.account_id = auth_info.chatgpt_account_id
        end
    end

    -- Cache new tokens (including rotated refresh_token!)
    oauth_token_cache:set(OAUTH_CACHE_KEY, {
        access_token = new_access,
        refresh_token = new_refresh,
        expires = new_expires,
    }, expires_in - 60)

    core.log.info("oauth token refreshed successfully, expires_in: ", expires_in,
                  "s, new_refresh: ", new_refresh:sub(1, 20), "...")

    httpc:set_keepalive(60000, 5)

    return new_access
end


--- Resolve the access token from auth config
--- Supports: passthrough (from client request), oauth, and header-based auth
--- @param auth table  auth config from route
--- @param ctx table   request context (for passthrough mode)
local function resolve_access_token(auth, ctx)
    if not auth then
        return nil, "no auth config"
    end

    -- Passthrough mode: forward client's Authorization header directly
    if auth.passthrough then
        local client_auth = core.request.header(ctx, "Authorization")
        if client_auth then
            if core.string.has_prefix(client_auth, "Bearer ") then
                return client_auth:sub(8)
            end
            return client_auth
        end
        return nil, "no Authorization header in client request (passthrough mode)"
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
    local access_token, err = resolve_access_token(auth, ctx)
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

    -- In passthrough mode, also forward relevant client headers
    if auth.passthrough then
        local passthrough_headers = {
            "ChatGPT-Account-Id", "openai-organization", "openai-project",
        }
        for _, h in ipairs(passthrough_headers) do
            local v = core.request.header(ctx, h)
            if v then
                headers[h] = v
            end
        end
    end

    headers["Content-Type"] = "application/json"
    headers["Authorization"] = "Bearer " .. access_token

    -- Add ChatGPT-Account-Id if configured (for oauth mode)
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
        core.log.info("using proxy for request to ", host, ":", port)
        httpc:set_proxy_options(proxy_opts)
    else
        core.log.warn("no proxy for request to ", host, ":", port, ", connecting directly")
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
