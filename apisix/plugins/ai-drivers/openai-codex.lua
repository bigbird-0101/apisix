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
local pairs = pairs
local type = type
local math = math
local setmetatable = setmetatable
local string = string
local table = table
local tostring = tostring
local os = os
local next = next

local _M = {}
local mt = { __index = _M }

local CONTENT_TYPE_JSON = "application/json"
local CONTENT_TYPE_EVENT_STREAM = "text/event-stream"
local CODEX_RESPONSES_PATH = "/backend-api/codex/responses"
local DEFAULT_CODEX_INSTRUCTIONS = "You are a helpful assistant."

local HTTP_INTERNAL_SERVER_ERROR = ngx.HTTP_INTERNAL_SERVER_ERROR
local HTTP_GATEWAY_TIMEOUT = ngx.HTTP_GATEWAY_TIMEOUT

-- OAuth token refresh endpoint
local OPENAI_TOKEN_ENDPOINT = "https://auth.openai.com/oauth/token"

-- Cache refreshed tokens (survives across requests within worker)
local oauth_token_cache = lrucache.new(256)
local unsupported_param_cache = lrucache.new(256)


function _M.new(opt)
    local self = setmetatable(opt or {}, mt)
    self.host = self.host or "chatgpt.com"
    self.path = self.path or CODEX_RESPONSES_PATH
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


local function normalize_response_usage(usage)
    if type(usage) ~= "table" then
        return {
            input_tokens = 0,
            output_tokens = 0,
            total_tokens = 0,
        }
    end

    local input_tokens = usage.input_tokens or usage.prompt_tokens or 0
    local output_tokens = usage.output_tokens or usage.completion_tokens or 0
    local total_tokens = usage.total_tokens or (input_tokens + output_tokens)

    return {
        input_tokens = input_tokens,
        output_tokens = output_tokens,
        total_tokens = total_tokens,
    }
end


local function build_synthetic_id(prefix, ctx)
    local request_id = ctx and ctx.var and ctx.var.request_id
    if type(request_id) == "string" and request_id ~= "" then
        return prefix .. "_" .. request_id
    end

    return prefix .. "_" .. tostring(math.floor(ngx_now() * 1000))
end


local function build_assistant_output_item(item_id, text, status)
    return {
        type = "message",
        id = item_id,
        role = "assistant",
        content = {
            {
                type = "output_text",
                text = text or "",
            },
        },
        status = status,
    }
end


local function build_response_resource(params)
    return {
        id = params.id,
        object = "response",
        created_at = params.created_at or ngx.time(),
        status = params.status or "completed",
        model = params.model or "",
        output = params.output or {},
        usage = normalize_response_usage(params.usage),
        error = params.error,
    }
end


local function extract_text_from_content(content)
    if type(content) == "string" then
        return content
    end

    if type(content) ~= "table" then
        return ""
    end

    local parts = {}
    for _, part in ipairs(content) do
        if type(part) == "table" then
            if part.type == "input_text" or part.type == "output_text" or part.type == "text" then
                if type(part.text) == "string" and part.text ~= "" then
                    table.insert(parts, part.text)
                end
            end
        end
    end

    return table.concat(parts, "\n")
end


local function extract_text_from_output(output)
    if type(output) ~= "table" then
        return ""
    end

    local parts = {}
    for _, item in ipairs(output) do
        if type(item) == "table" and item.type == "message" then
            local content = extract_text_from_content(item.content)
            if content ~= "" then
                table.insert(parts, content)
            end
        end
    end

    return table.concat(parts, "\n\n")
end


local function extract_text_from_choices(choices)
    if type(choices) ~= "table" then
        return ""
    end

    local parts = {}
    for _, choice in ipairs(choices) do
        if type(choice) == "table" then
            local message = choice.message
            if type(message) == "table" and type(message.content) == "string"
                    and message.content ~= "" then
                table.insert(parts, message.content)
            end
        end
    end

    return table.concat(parts, "\n\n")
end


local function extract_response_text(body)
    if type(body) ~= "table" then
        return ""
    end

    if type(body.output_text) == "string" and body.output_text ~= "" then
        return body.output_text
    end

    local output_text = extract_text_from_output(body.output)
    if output_text ~= "" then
        return output_text
    end

    return extract_text_from_choices(body.choices)
end


local function normalize_tools(tools)
    if type(tools) ~= "table" then
        return tools
    end

    local normalized_tools = {}
    for _, tool in ipairs(tools) do
        if type(tool) == "table" and tool.type == "function"
                and type(tool["function"]) == "table" and not tool.name then
            table.insert(normalized_tools, {
                type = "function",
                name = tool["function"].name,
                description = tool["function"].description,
                parameters = tool["function"].parameters,
                strict = tool["function"].strict,
            })
        else
            table.insert(normalized_tools, tool)
        end
    end

    return normalized_tools
end


local function normalize_upstream_path(path)
    if type(path) ~= "string" or path == "" or path == "/" then
        return CODEX_RESPONSES_PATH
    end

    local normalized = path:gsub("/+$", "")
    if normalized == "" then
        return CODEX_RESPONSES_PATH
    end

    if normalized:sub(1, 1) ~= "/" then
        normalized = "/" .. normalized
    end

    if normalized == "/backend-api"
            or normalized == "/backend-api/responses"
            or normalized == "/backend-api/codex" then
        return CODEX_RESPONSES_PATH
    end

    return normalized
end


local function normalize_request_body(request_table)
    local normalized = core.table.clone(request_table) or {}
    local compat = {
        stripped_item_references = 0,
        stripped_reasoning_items = 0,
    }

    normalized.type = nil
    normalized.stream_options = nil
    normalized.store = false
    normalized.max_output_tokens = nil

    if normalized.tools then
        normalized.tools = normalize_tools(normalized.tools)
    end

    local instructions = {}
    if type(normalized.instructions) == "string" and normalized.instructions ~= "" then
        table.insert(instructions, normalized.instructions)
    end

    if type(normalized.input) == "table" then
        local filtered_input = {}
        for _, item in ipairs(normalized.input) do
            if type(item) == "table" and item.type == "item_reference" then
                compat.stripped_item_references = compat.stripped_item_references + 1
            elseif type(item) == "table" and item.type == "reasoning" then
                compat.stripped_reasoning_items = compat.stripped_reasoning_items + 1
            elseif type(item) == "table" and item.type == "message"
                    and (item.role == "system" or item.role == "developer") then
                local content = extract_text_from_content(item.content)
                if content ~= "" then
                    table.insert(instructions, content)
                end
            else
                table.insert(filtered_input, item)
            end
        end
        normalized.input = filtered_input
    end

    if #instructions > 0 then
        normalized.instructions = table.concat(instructions, "\n\n")
    else
        normalized.instructions = DEFAULT_CODEX_INSTRUCTIONS
    end

    return normalized, compat
end


local function split_param_path(param_path)
    if type(param_path) ~= "string" or param_path == "" then
        return nil
    end

    local parts = {}
    for part in param_path:gmatch("[^%.]+") do
        if part ~= "" then
            table.insert(parts, part)
        end
    end

    if #parts == 0 then
        return nil
    end

    return parts
end


local function is_safe_to_strip_param(param_path)
    local parts = split_param_path(param_path)
    if not parts then
        return false
    end

    local top_level = parts[1]
    if top_level == "model"
            or top_level == "input"
            or top_level == "instructions"
            or top_level == "stream"
            or top_level == "tools"
            or top_level == "tool_choice"
            or top_level == "previous_response_id" then
        return false
    end

    return true
end


local function remove_param_by_path(tbl, param_path)
    local parts = split_param_path(param_path)
    if not parts or type(tbl) ~= "table" then
        return false
    end

    local current = tbl
    local parents = {}
    for i = 1, #parts - 1 do
        if type(current[parts[i]]) ~= "table" then
            return false
        end

        parents[i] = {
            node = current,
            key = parts[i],
        }
        current = current[parts[i]]
    end

    local leaf = parts[#parts]
    if current[leaf] == nil then
        return false
    end

    current[leaf] = nil

    for i = #parents, 1, -1 do
        local parent = parents[i]
        if type(parent.node[parent.key]) == "table"
                and next(parent.node[parent.key]) == nil then
            parent.node[parent.key] = nil
        else
            break
        end
    end

    return true
end


local function build_unsupported_cache_key(host, path)
    return (host or "") .. "|" .. (path or "")
end


local function remember_unsupported_param(cache_key, param_path)
    if not cache_key or not param_path then
        return
    end

    local cached = unsupported_param_cache:get(cache_key)
    if type(cached) ~= "table" then
        cached = {}
    end

    cached[param_path] = true
    unsupported_param_cache:set(cache_key, cached)
end


local function apply_cached_unsupported_params(cache_key, request_table)
    if not cache_key or type(request_table) ~= "table" then
        return {}
    end

    local cached = unsupported_param_cache:get(cache_key)
    if type(cached) ~= "table" then
        return {}
    end

    local stripped = {}
    for param_path in pairs(cached) do
        if remove_param_by_path(request_table, param_path) then
            table.insert(stripped, param_path)
        end
    end

    return stripped
end


local function looks_like_sse_payload(body)
    if type(body) ~= "string" then
        return false
    end

    local trimmed = body:gsub("^%s+", "")
    return core.string.has_prefix(trimmed, "event:")
        or core.string.has_prefix(trimmed, "data:")
end


local function strip_persisted_state_inputs(input, strip_function_call_ids)
    if type(input) ~= "table" then
        return {
            removed_item_references = 0,
            removed_reasoning_items = 0,
            stripped_function_call_ids = 0,
        }, input
    end

    local filtered = {}
    local stats = {
        removed_item_references = 0,
        removed_reasoning_items = 0,
        stripped_function_call_ids = 0,
    }
    for _, item in ipairs(input) do
        if type(item) == "table" and item.type == "item_reference" then
            stats.removed_item_references = stats.removed_item_references + 1
        elseif type(item) == "table" and item.type == "reasoning" then
            stats.removed_reasoning_items = stats.removed_reasoning_items + 1
        else
            if strip_function_call_ids and type(item) == "table"
                    and item.type == "function_call"
                    and type(item.id) == "string" and item.id ~= "" then
                item = core.table.clone(item) or {}
                item.id = nil
                stats.stripped_function_call_ids = stats.stripped_function_call_ids + 1
            end
            table.insert(filtered, item)
        end
    end

    return stats, filtered
end


local function recover_missing_persisted_items(request_table)
    if type(request_table) ~= "table" then
        return nil
    end

    local stripped_input_stats = {
        removed_item_references = 0,
        removed_reasoning_items = 0,
        stripped_function_call_ids = 0,
    }
    if type(request_table.input) == "table" then
        stripped_input_stats, request_table.input =
            strip_persisted_state_inputs(request_table.input, true)
    end

    local removed_previous_response_id = request_table.previous_response_id ~= nil
    request_table.previous_response_id = nil

    if stripped_input_stats.removed_item_references == 0
            and stripped_input_stats.removed_reasoning_items == 0
            and stripped_input_stats.stripped_function_call_ids == 0
            and not removed_previous_response_id then
        return nil
    end

    return {
        removed_item_references = stripped_input_stats.removed_item_references,
        removed_reasoning_items = stripped_input_stats.removed_reasoning_items,
        stripped_function_call_ids = stripped_input_stats.stripped_function_call_ids,
        removed_previous_response_id = removed_previous_response_id,
    }
end


local function resolve_error_type(status)
    if status == 401 or status == 403 then
        return "authentication_error"
    end

    if status == 429 then
        return "rate_limit_error"
    end

    if status and status >= 500 then
        return "api_error"
    end

    return "invalid_request_error"
end


local function extract_error_message(body, status)
    if type(body) == "table" then
        if type(body.error) == "table" then
            if type(body.error.message) == "string" and body.error.message ~= "" then
                return body.error.message
            end
            if type(body.error.detail) == "string" and body.error.detail ~= "" then
                return body.error.detail
            end
        end

        if type(body.detail) == "string" and body.detail ~= "" then
            return body.detail
        end

        if type(body.message) == "string" and body.message ~= "" then
            return body.message
        end
    end

    return "request failed with status " .. tostring(status or 500)
end


local function extract_unsupported_param(body, status)
    local message = extract_error_message(body, status)
    if type(message) ~= "string" or message == "" then
        return nil, nil
    end

    local patterns = {
        "[Uu]nsupported parameter:%s*[\"'`]?(.-)[\"'`]?%s*$",
        "[Uu]nknown parameter:%s*[\"'`]?(.-)[\"'`]?%s*$",
        "[Uu]nrecognized request argument supplied:%s*[\"'`]?(.-)[\"'`]?%s*$",
    }

    for _, pattern in ipairs(patterns) do
        local param_path = message:match(pattern)
        if type(param_path) == "string" and param_path ~= "" then
            param_path = param_path:gsub("^%s+", ""):gsub("%s+$", "")
            param_path = param_path:gsub("^%$%.", "")
            if param_path ~= "" then
                return param_path, message
            end
        end
    end

    return nil, message
end


local function should_retry_missing_persisted_items(body, status)
    if not status or status < 400 or status >= 500 then
        return nil
    end

    local message = extract_error_message(body, status)
    if type(message) ~= "string" or message == "" then
        return nil
    end

    if message:find("Items are not persisted when")
            and message:find("store")
            and message:find("set to false") then
        return message
    end

    return nil
end


local function should_retry_store_must_be_false(body, status)
    if not status or status < 400 or status >= 500 then
        return nil
    end

    local message = extract_error_message(body, status)
    if type(message) ~= "string" or message == "" then
        return nil
    end

    if message:find("Store must be set to false") then
        return message
    end

    return nil
end


local function build_error_body(body, status)
    if type(body) == "table" and type(body.error) == "table"
            and type(body.error.message) == "string" then
        local err = core.table.clone(body.error)
        err.type = err.type or resolve_error_type(status)
        return {
            error = err,
        }
    end

    return {
        error = {
            message = extract_error_message(body, status),
            type = resolve_error_type(status),
        },
    }
end


local function normalize_response_body(ctx, body, status)
    if status and status >= 400 then
        return build_error_body(body, status)
    end

    if type(body) ~= "table" then
        local text = body and tostring(body) or ""
        return build_response_resource({
            id = build_synthetic_id("resp", ctx),
            model = ctx.var.llm_model or "",
            output = {
                build_assistant_output_item(build_synthetic_id("msg", ctx), text, "completed"),
            },
        })
    end

    if type(body.output) == "table" then
        local normalized = core.table.clone(body)
        normalized.id = normalized.id or build_synthetic_id("resp", ctx)
        normalized.object = "response"
        normalized.created_at = normalized.created_at or ngx.time()
        normalized.model = normalized.model or ctx.var.llm_model or ""
        normalized.status = normalized.status or (normalized.error and "failed" or "completed")
        normalized.usage = normalize_response_usage(normalized.usage)
        return normalized
    end

    local text = extract_response_text(body)
    return build_response_resource({
        id = body.id or build_synthetic_id("resp", ctx),
        model = body.model or ctx.var.llm_model or "",
        status = body.status or "completed",
        output = {
            build_assistant_output_item(
                build_synthetic_id("msg", ctx),
                text,
                "completed"
            ),
        },
        usage = body.usage,
        error = body.error,
    })
end


local function update_ctx_usage(ctx, usage)
    local normalized = normalize_usage(usage)
    if not normalized then
        return
    end

    ctx.ai_token_usage = normalized
    ctx.var.llm_prompt_tokens = normalized.prompt_tokens or 0
    ctx.var.llm_completion_tokens = normalized.completion_tokens or 0
end


local function decode_buffered_sse_events(state, chunk)
    local buffer = (state.pending_sse or "") .. (chunk or "")
    local events = {}

    while true do
        local pos = string.find(buffer, "\n\n", 1, true)
        if not pos then
            break
        end

        local raw_event = string.sub(buffer, 1, pos + 1)
        buffer = string.sub(buffer, pos + 2)

        local decoded = sse.decode(raw_event)
        for _, event in ipairs(decoded) do
            table.insert(events, event)
        end
    end

    state.pending_sse = buffer
    return events
end


local function decode_complete_sse_events(raw_body)
    local state = {
        pending_sse = "",
    }
    local events = decode_buffered_sse_events(state, raw_body)

    if state.pending_sse and state.pending_sse ~= "" then
        local trailing_events = sse.decode(state.pending_sse .. "\n\n")
        for _, event in ipairs(trailing_events) do
            table.insert(events, event)
        end
    end

    return events
end


local function is_openresponses_event(event_type)
    return type(event_type) == "string"
            and (core.string.has_prefix(event_type, "response.")
            or event_type == "rate_limits.updated"
            or event_type == "error")
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


local function encode_sse_json_event(event_type, body)
    local payload, err = core.json.encode(body)
    if not payload then
        return nil, err
    end

    return sse.encode({
        type = event_type,
        data = payload,
    })
end


local function update_stream_state_from_response_event(ctx, state, data)
    if type(data) ~= "table" then
        return
    end

    if data.type == "response.output_text.delta" and type(data.delta) == "string" then
        table.insert(state.contents, data.delta)
        ctx.llm_response_contents_in_chunk = { data.delta }
        ctx.var.llm_response_text = table.concat(state.contents, "")
        return
    end

    if data.type == "response.output_text.done" and type(data.text) == "string" then
        state.final_text = data.text
        ctx.var.llm_response_text = data.text
        return
    end

    if data.type == "response.output_item.done"
            and type(data.item) == "table" and data.item.type == "message" then
        local text = extract_text_from_content(data.item.content)
        if text ~= "" then
            state.final_text = text
            ctx.var.llm_response_text = text
        end
        return
    end

    local response = data.response
    if type(response) == "table" then
        if data.type == "response.completed" or data.type == "response.failed" then
            state.completed = true
        end

        if type(response.usage) == "table" then
            state.usage = response.usage
            update_ctx_usage(ctx, response.usage)
        end

        local text = extract_response_text(response)
        if text ~= "" then
            state.final_text = text
            if #state.contents == 0 then
                table.insert(state.contents, text)
            end
            ctx.var.llm_response_text = text
        end
        return
    end

    if type(data.usage) == "table" then
        state.usage = data.usage
        update_ctx_usage(ctx, data.usage)
    end
end


local function build_chat_completion_stream_prefix(ctx, state)
    if state.started then
        return {}
    end

    state.started = true
    local response = build_response_resource({
        id = state.response_id,
        model = ctx.var.llm_model or "",
        status = "in_progress",
        output = {},
    })

    local output_item = build_assistant_output_item(state.output_item_id, "", "in_progress")

    return {
        encode_sse_json_event("response.created", {
            type = "response.created",
            response = response,
        }),
        encode_sse_json_event("response.in_progress", {
            type = "response.in_progress",
            response = response,
        }),
        encode_sse_json_event("response.output_item.added", {
            type = "response.output_item.added",
            output_index = 0,
            item = output_item,
        }),
        encode_sse_json_event("response.content_part.added", {
            type = "response.content_part.added",
            item_id = state.output_item_id,
            output_index = 0,
            content_index = 0,
            part = {
                type = "output_text",
                text = "",
            },
        }),
    }
end


local function build_chat_completion_stream_suffix(ctx, state, status)
    if state.completed then
        return {}
    end

    state.completed = true

    local text = state.final_text
    if type(text) ~= "string" or text == "" then
        text = table.concat(state.contents, "")
    end

    ctx.var.llm_response_text = text

    local output_item = build_assistant_output_item(state.output_item_id, text, "completed")
    local response = build_response_resource({
        id = state.response_id,
        model = ctx.var.llm_model or "",
        status = status or "completed",
        output = {
            output_item,
        },
        usage = state.usage,
    })

    return {
        encode_sse_json_event("response.output_text.done", {
            type = "response.output_text.done",
            item_id = state.output_item_id,
            output_index = 0,
            content_index = 0,
            text = text,
        }),
        encode_sse_json_event("response.content_part.done", {
            type = "response.content_part.done",
            item_id = state.output_item_id,
            output_index = 0,
            content_index = 0,
            part = {
                type = "output_text",
                text = text,
            },
        }),
        encode_sse_json_event("response.output_item.done", {
            type = "response.output_item.done",
            output_index = 0,
            item = output_item,
        }),
        encode_sse_json_event("response.completed", {
            type = "response.completed",
            response = response,
        }),
    }
end


local function translate_stream_event(ctx, state, event)
    if event.type == "done" then
        ctx.var.llm_request_done = true
        local output = {}
        local suffix = build_chat_completion_stream_suffix(ctx, state, "completed")
        for _, item in ipairs(suffix) do
            if item then
                table.insert(output, item)
            end
        end
        table.insert(output, sse.encode({
            type = "done",
            data = "[DONE]",
        }))
        return table.concat(output, "")
    end

    local raw_data = event.data
    if not raw_data or raw_data == "" then
        return nil
    end

    local data = core.json.decode(raw_data)
    if not data then
        return sse.encode({
            type = event.type,
            data = raw_data,
        })
    end

    if is_openresponses_event(data.type) then
        update_stream_state_from_response_event(ctx, state, data)
        if data.type == "response.completed" or data.type == "response.failed" then
            core.log.info("normalized OpenAI Codex stream event: ",
                core.json.delay_encode(data))
        end
        return encode_sse_json_event(data.type, data)
    end

    if data.object == "response" and type(data.output) == "table" then
        local normalized = normalize_response_body(ctx, data, 200)
        update_stream_state_from_response_event(ctx, state, {
            type = "response.completed",
            response = normalized,
        })
        core.log.info("normalized OpenAI Codex stream response object: ",
            core.json.delay_encode(normalized))
        return encode_sse_json_event("response.completed", {
            type = "response.completed",
            response = normalized,
        })
    end

    if type(data.choices) == "table" and #data.choices > 0 then
        local output = {}
        local prefix = build_chat_completion_stream_prefix(ctx, state)
        for _, item in ipairs(prefix) do
            if item then
                table.insert(output, item)
            end
        end

        if type(data.usage) == "table" then
            state.usage = data.usage
            update_ctx_usage(ctx, data.usage)
        end

        for _, choice in ipairs(data.choices) do
            if type(choice) == "table" and type(choice.delta) == "table"
                    and type(choice.delta.content) == "string"
                    and choice.delta.content ~= "" then
                table.insert(state.contents, choice.delta.content)
                ctx.llm_response_contents_in_chunk = { choice.delta.content }
                ctx.var.llm_response_text = table.concat(state.contents, "")
                table.insert(output, encode_sse_json_event("response.output_text.delta", {
                    type = "response.output_text.delta",
                    item_id = state.output_item_id,
                    output_index = 0,
                    content_index = 0,
                    delta = choice.delta.content,
                }))
            end

            if type(choice) == "table" and choice.finish_reason then
                local suffix = build_chat_completion_stream_suffix(ctx, state, "completed")
                for _, item in ipairs(suffix) do
                    if item then
                        table.insert(output, item)
                    end
                end
                if state.completed then
                    core.log.info("normalized OpenAI Codex chat-style stream completion: ",
                        core.json.delay_encode(build_response_resource({
                            id = state.response_id,
                            model = ctx.var.llm_model or "",
                            status = "completed",
                            output = {
                                build_assistant_output_item(
                                    state.output_item_id,
                                    state.final_text or table.concat(state.contents, ""),
                                    "completed"
                                ),
                            },
                            usage = state.usage,
                        })))
                end
            end
        end

        return table.concat(output, "")
    end

    if type(data.usage) == "table" then
        state.usage = data.usage
        update_ctx_usage(ctx, data.usage)
    end

    return sse.encode({
        type = event.type,
        data = raw_data,
    })
end


local function process_sse_payload(ctx, raw_body)
    local stream_state = {
        pending_sse = "",
        contents = {},
        response_id = build_synthetic_id("resp", ctx),
        output_item_id = build_synthetic_id("msg", ctx),
    }
    local translated = {}
    local normalized_body
    local events = decode_complete_sse_events(raw_body)

    for _, event in ipairs(events) do
        local raw_data = event.data
        if raw_data and raw_data ~= "" and raw_data ~= "[DONE]" then
            local data = core.json.decode(raw_data)
            if type(data) == "table" then
                if type(data.type) == "string"
                        and (data.type == "response.completed" or data.type == "response.failed")
                        and type(data.response) == "table" then
                    normalized_body = normalize_response_body(ctx, data.response,
                        data.type == "response.failed" and 500 or 200)
                elseif data.object == "response" and type(data.output) == "table" then
                    normalized_body = normalize_response_body(ctx, data, 200)
                end
            end
        end

        local translated_event = translate_stream_event(ctx, stream_state, event)
        if translated_event then
            table.insert(translated, translated_event)
        end
    end

    if not normalized_body then
        local text = stream_state.final_text or table.concat(stream_state.contents, "")
        if text ~= "" or stream_state.completed or stream_state.usage then
            normalized_body = build_response_resource({
                id = stream_state.response_id,
                model = ctx.var.llm_model or "",
                status = stream_state.completed and "completed" or "incomplete",
                output = {
                    build_assistant_output_item(
                        stream_state.output_item_id,
                        text,
                        stream_state.completed and "completed" or "incomplete"
                    ),
                },
                usage = stream_state.usage,
            })
        end
    end

    return table.concat(translated, ""), normalized_body
end


local function read_response(conf, ctx, res)
    local content_type = res.headers["Content-Type"]
    local requested_stream = type(ctx.var.llm_request_body) == "table"
        and ctx.var.llm_request_body.stream == true
    core.response.set_header("Content-Type", content_type)

    -- Streaming response (SSE)
    if content_type and core.string.find(content_type, CONTENT_TYPE_EVENT_STREAM) then
        local body_reader = res.body_reader
        if not body_reader then
            core.log.warn("AI service sent no response body")
            return HTTP_INTERNAL_SERVER_ERROR
        end

        core.response.set_header("Content-Type", CONTENT_TYPE_EVENT_STREAM)
        local stream_state = {
            pending_sse = "",
            contents = {},
            response_id = build_synthetic_id("resp", ctx),
            output_item_id = build_synthetic_id("msg", ctx),
        }

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
            local events = decode_buffered_sse_events(stream_state, chunk)
            local translated = {}
            for _, event in ipairs(events) do
                local translated_event = translate_stream_event(ctx, stream_state, event)
                if translated_event then
                    table.insert(translated, translated_event)
                end
            end

            if #translated > 0 then
                plugin.lua_response_filter(ctx, res.headers, table.concat(translated, ""))
            end
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

    local res_body = core.json.decode(raw_res_body)
    if not res_body then
        if looks_like_sse_payload(raw_res_body) then
            core.log.warn("upstream returned SSE payload without event-stream content-type")
            local translated_sse, normalized_sse_body = process_sse_payload(ctx, raw_res_body)

            if requested_stream then
                core.response.set_header("Content-Type", CONTENT_TYPE_EVENT_STREAM)
                plugin.lua_response_filter(ctx, res.headers,
                    translated_sse ~= "" and translated_sse or raw_res_body)
                return
            end

            if normalized_sse_body then
                core.log.info("normalized OpenAI Codex SSE fallback response body: ",
                    core.json.delay_encode(normalized_sse_body))

                local response_usage = normalized_sse_body.usage
                if response_usage then
                    update_ctx_usage(ctx, response_usage)
                end

                local response_text = extract_response_text(normalized_sse_body)
                if response_text ~= "" then
                    ctx.var.llm_response_text = response_text
                end

                local encoded_sse_body, encode_sse_err = core.json.encode(normalized_sse_body)
                if not encoded_sse_body then
                    core.log.error("failed to encode normalized SSE fallback body: ",
                        encode_sse_err)
                    return HTTP_INTERNAL_SERVER_ERROR
                end

                core.response.set_header("Content-Type", CONTENT_TYPE_JSON)
                plugin.lua_response_filter(ctx, res.headers, encoded_sse_body)
                return
            end
        end

        if res.status >= 400 then
            local error_body = build_error_body({
                message = raw_res_body,
            }, res.status)
            local encoded, encode_err = core.json.encode(error_body)
            if not encoded then
                core.log.error("failed to encode error body: ", encode_err)
                return HTTP_INTERNAL_SERVER_ERROR
            end
            core.response.set_header("Content-Type", CONTENT_TYPE_JSON)
            plugin.lua_response_filter(ctx, res.headers, encoded)
            return
        end

        core.log.warn("invalid response body from ai service: ", raw_res_body)
        plugin.lua_response_filter(ctx, res.headers, raw_res_body)
        return
    end

    local normalized_body = normalize_response_body(ctx, res_body, res.status)
    core.log.info("normalized OpenAI Codex response body: ",
        core.json.delay_encode(normalized_body))
    local response_usage
    if res.status < 400 then
        response_usage = normalized_body.usage or res_body.usage
    elseif type(res_body) == "table" then
        response_usage = res_body.usage
    end

    if response_usage then
        update_ctx_usage(ctx, response_usage)
    end

    local response_text = extract_response_text(normalized_body)
    if response_text ~= "" then
        ctx.var.llm_response_text = response_text
    end

    local encoded_body, encode_err = core.json.encode(normalized_body)
    if not encoded_body then
        core.log.error("failed to encode normalized response body: ", encode_err)
        return HTTP_INTERNAL_SERVER_ERROR
    end

    core.response.set_header("Content-Type", CONTENT_TYPE_JSON)
    plugin.lua_response_filter(ctx, res.headers, encoded_body)
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

    local path = normalize_upstream_path(parsed_url and parsed_url.path or self.path)

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

    local normalized_request = core.table.clone(request_table) or {}
    if extra_opts.model_options then
        for opt, val in pairs(extra_opts.model_options) do
            normalized_request[opt] = val
        end
    end
    local stripped_store = normalized_request.store
    local stripped_max_output_tokens = normalized_request.max_output_tokens
    local request_compat
    normalized_request, request_compat = normalize_request_body(normalized_request)
    if stripped_store == true then
        core.log.info("overriding store=true to store=false for OpenAI Codex compatibility")
    end
    if request_compat and request_compat.stripped_item_references > 0 then
        core.log.info("stripping unsupported item_reference inputs for OpenAI Codex backend: ",
            request_compat.stripped_item_references)
    end
    if request_compat and request_compat.stripped_reasoning_items > 0 then
        core.log.info("stripping unsupported reasoning inputs for OpenAI Codex backend: ",
            request_compat.stripped_reasoning_items)
    end
    if normalized_request.previous_response_id then
        core.log.info("OpenAI Codex request includes previous_response_id: ",
            normalized_request.previous_response_id)
    end
    if stripped_max_output_tokens ~= nil then
        core.log.info("stripping unsupported max_output_tokens for OpenAI Codex backend: ",
            stripped_max_output_tokens)
    end
    local unsupported_cache_key = build_unsupported_cache_key(host, path)
    local cached_stripped = apply_cached_unsupported_params(unsupported_cache_key, normalized_request)
    if #cached_stripped > 0 then
        core.log.info("pre-stripped cached unsupported OpenAI Codex params: ",
            table.concat(cached_stripped, ", "))
    end
    ctx.var.llm_request_body = normalized_request

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

    local max_adaptive_retries = 5
    local attempt = 0
    local res
    while true do
        attempt = attempt + 1

        local req_json, encode_err = core.json.encode(normalized_request)
        if not req_json then
            return 500, "failed to encode request body: " .. (encode_err or "unknown error")
        end

        params.body = req_json

        res, err = httpc:request(params)
        if not res then
            core.log.warn("failed to send request to OpenAI Codex API: ", err)
            return handle_error(err)
        end

        if res.status < 400 or res.status >= 500
                or res.status == 401 or res.status == 403 or res.status == 429 then
            break
        end

        local content_type = res.headers["Content-Type"]
        if content_type and core.string.find(content_type, CONTENT_TYPE_EVENT_STREAM) then
            break
        end

        local raw_err_body, read_err = res:read_body()
        if not raw_err_body then
            core.log.warn("failed to read error response body from OpenAI Codex API: ", read_err)
            return handle_error(read_err)
        end

        local err_body = core.json.decode(raw_err_body) or {
            message = raw_err_body,
        }
        local unsupported_param, unsupported_message = extract_unsupported_param(err_body,
            res.status)

        local should_retry = false
        if unsupported_param and is_safe_to_strip_param(unsupported_param)
                and attempt < max_adaptive_retries
                and remove_param_by_path(normalized_request, unsupported_param) then
            remember_unsupported_param(unsupported_cache_key, unsupported_param)
            ctx.var.llm_request_body = normalized_request
            core.log.warn("retrying OpenAI Codex request without unsupported parameter: ",
                unsupported_param, ", message: ", unsupported_message)
            should_retry = true
        end

        if not should_retry then
            local store_false_message = should_retry_store_must_be_false(err_body, res.status)
            if store_false_message and attempt < max_adaptive_retries
                    and normalized_request.store ~= false then
                normalized_request.store = false
                ctx.var.llm_request_body = normalized_request
                core.log.warn("retrying OpenAI Codex request with store=false, message: ",
                    store_false_message)
                should_retry = true
            end
        end

        if not should_retry then
            local persistence_message = should_retry_missing_persisted_items(err_body, res.status)
            if persistence_message and attempt < max_adaptive_retries then
                local recovered = recover_missing_persisted_items(normalized_request)
                if recovered then
                    ctx.var.llm_request_body = normalized_request
                    core.log.warn("retrying OpenAI Codex request after persistence recovery, "
                        .. "removed_item_references=", recovered.removed_item_references,
                        ", removed_reasoning_items=", recovered.removed_reasoning_items,
                        ", stripped_function_call_ids=", recovered.stripped_function_call_ids,
                        ", removed_previous_response_id=", recovered.removed_previous_response_id,
                        ", message: ", persistence_message)
                    should_retry = true
                end
            end
        end

        if not should_retry then
            local buffered_res = {
                status = res.status,
                headers = res.headers,
            }
            function buffered_res:read_body()
                return raw_err_body
            end

            local code, body = read_response(conf, ctx, buffered_res)

            if conf.keepalive then
                local keepalive_ok, keepalive_err =
                    httpc:set_keepalive(conf.keepalive_timeout, conf.keepalive_pool)
                if not keepalive_ok then
                    core.log.warn("failed to keepalive connection: ", keepalive_err)
                end
            end

            return code, body
        end
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
