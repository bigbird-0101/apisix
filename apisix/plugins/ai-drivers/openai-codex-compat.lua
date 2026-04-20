--
-- OpenAI-compatible driver for ChatGPT Codex backend.
-- Accepts standard /v1/chat/completions requests, translates to the
-- /v1/responses format, forwards to chatgpt.com/backend-api/responses
-- with OAuth, then translates the response back to Chat Completions format.
--
-- Use case: let any OpenAI SDK / client talk to Codex through APISIX
-- without knowing about the Responses API or OAuth internals.
--

local core = require("apisix.core")
local http = require("resty.http")
local sse  = require("apisix.plugins.ai-drivers.sse")
local plugin = require("apisix.plugin")
local lrucache = require("resty.lrucache")
local proxy_utils = require("apisix.plugins.ai-drivers.proxy-utils")

local ngx = ngx
local ngx_now = ngx.now
local ngx_time = ngx.time
local ipairs = ipairs
local pairs = pairs
local type = type
local table = table
local math = math
local tostring = tostring
local string = string

local _M = {}

local CONTENT_TYPE_JSON = "application/json"
local DEFAULT_HOST = "chatgpt.com"
-- Codex CLI uses /backend-api/codex/responses (NOT /backend-api/responses)
-- The /codex/ segment is required for ChatGPT Plus/Pro OAuth tokens and
-- is the only path that supports non-codex models like gpt-5.4.
local DEFAULT_PATH = "/backend-api/codex/responses"

local HTTP_INTERNAL_SERVER_ERROR = ngx.HTTP_INTERNAL_SERVER_ERROR
local HTTP_GATEWAY_TIMEOUT = ngx.HTTP_GATEWAY_TIMEOUT

local build_proxy_opts = proxy_utils.build_proxy_opts
local oauth_token_cache = lrucache.new(256)


local function handle_error(err)
    if core.string.find(err, "timeout") then
        return HTTP_GATEWAY_TIMEOUT
    end
    return HTTP_INTERNAL_SERVER_ERROR
end


-- ============================================================
-- OAuth helpers (shared with openai-codex)
-- ============================================================

local function decode_jwt_payload(token)
    if not token then return nil end
    local dot1 = token:find(".", 1, true)
    if not dot1 then return nil end
    local dot2 = token:find(".", dot1 + 1, true)
    if not dot2 then return nil end

    local payload_b64 = token:sub(dot1 + 1, dot2 - 1)
    local padding = (4 - #payload_b64 % 4) % 4
    payload_b64 = payload_b64 .. ("="):rep(padding)
    payload_b64 = payload_b64:gsub("-", "+"):gsub("_", "/")

    local payload_json = ngx.decode_base64(payload_b64)
    if not payload_json then return nil end
    return core.json.decode(payload_json)
end


local function extract_token_claims(oauth_conf)
    if oauth_conf.client_id and oauth_conf.account_id then return end
    local claims = decode_jwt_payload(oauth_conf.access_token)
    if not claims then return end
    oauth_conf.client_id = oauth_conf.client_id or claims.client_id
    if not oauth_conf.account_id then
        local auth_info = claims["https://api.openai.com/auth"]
        if auth_info then
            oauth_conf.account_id = auth_info.chatgpt_account_id
        end
    end
end


local function get_token_expiry_ms(access_token)
    local claims = decode_jwt_payload(access_token)
    if claims and claims.exp then return claims.exp * 1000 end
    return nil
end


local function build_cache_key(oauth_conf)
    return "codex_compat_oauth#" .. (oauth_conf.refresh_token or ""):sub(1, 32)
end


local function refresh_oauth_token(oauth_conf)
    extract_token_claims(oauth_conf)
    local cache_key = build_cache_key(oauth_conf)
    local cached = oauth_token_cache:get(cache_key)

    if cached then
        local now_ms = ngx_now() * 1000
        if cached.expires and cached.expires > now_ms then
            return cached.access_token
        end
        if cached.refresh_token then
            oauth_conf = core.table.clone(oauth_conf)
            oauth_conf.refresh_token = cached.refresh_token
        end
    end

    if not cached then
        local expires = oauth_conf.expires or get_token_expiry_ms(oauth_conf.access_token)
        if expires and expires > ngx_now() * 1000 then
            local ttl = math.floor((expires - ngx_now() * 1000) / 1000)
            oauth_token_cache:set(cache_key, {
                access_token = oauth_conf.access_token,
                refresh_token = oauth_conf.refresh_token,
                expires = expires,
            }, ttl)
            return oauth_conf.access_token
        end
    end

    core.log.info("codex-compat: refreshing oauth token")
    local httpc = http.new()
    httpc:set_timeout(10000)
    local proxy_opts = build_proxy_opts()
    if proxy_opts then httpc:set_proxy_options(proxy_opts) end

    local ok, err = httpc:connect({
        scheme = "https", host = "auth.openai.com", port = 443,
        ssl_verify = true, ssl_server_name = "auth.openai.com",
    })
    if not ok then
        core.log.error("codex-compat: connect auth.openai.com failed: ", err)
        return oauth_conf.access_token
    end

    local body = "grant_type=refresh_token&refresh_token=" .. ngx.escape_uri(oauth_conf.refresh_token)
    if oauth_conf.client_id then
        body = body .. "&client_id=" .. ngx.escape_uri(oauth_conf.client_id)
    end

    local res, err = httpc:request({
        method = "POST", path = "/oauth/token",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Accept"] = "application/json",
        },
        body = body,
    })
    if not res then return oauth_conf.access_token end

    local res_body = res:read_body() or ""
    if res.status ~= 200 then
        core.log.error("codex-compat: refresh failed: ", res.status, " ", res_body)
        if cached and cached.access_token then return cached.access_token end
        return oauth_conf.access_token
    end

    local data = core.json.decode(res_body) or {}
    local new_access = data.access_token
    if not new_access then return oauth_conf.access_token end
    local new_refresh = data.refresh_token or oauth_conf.refresh_token
    local expires_in = data.expires_in or 3600
    local new_expires = ngx_now() * 1000 + expires_in * 1000

    local new_claims = decode_jwt_payload(new_access)
    if new_claims then
        local auth_info = new_claims["https://api.openai.com/auth"]
        if auth_info and auth_info.chatgpt_account_id then
            oauth_conf.account_id = auth_info.chatgpt_account_id
        end
    end

    oauth_token_cache:set(cache_key, {
        access_token = new_access,
        refresh_token = new_refresh,
        expires = new_expires,
    }, expires_in - 60)

    httpc:set_keepalive(60000, 5)
    return new_access
end


local function resolve_access_token(auth, ctx)
    if not auth then return nil, "no auth" end
    if auth.passthrough then
        local h = core.request.header(ctx, "Authorization")
        if h then
            return core.string.has_prefix(h, "Bearer ") and h:sub(8) or h
        end
        return nil, "no Authorization header"
    end
    if auth.oauth and auth.oauth.access_token then
        return refresh_oauth_token(auth.oauth)
    end
    if auth.header and auth.header["Authorization"] then
        local h = auth.header["Authorization"]
        return core.string.has_prefix(h, "Bearer ") and h:sub(8) or h
    end
    return nil, "no supported auth method"
end


-- ============================================================
-- Request translation: OpenAI Chat Completions -> Codex Responses
-- ============================================================

-- Extract text content from an OpenAI message (string or multimodal array).
local function extract_text_content(content)
    if type(content) == "string" then return content end
    if type(content) ~= "table" then return "" end
    local parts = {}
    for _, part in ipairs(content) do
        if type(part) == "table" and part.type == "text" and part.text then
            table.insert(parts, part.text)
        end
    end
    return table.concat(parts, "\n")
end


-- Convert OpenAI `messages` array into Codex Responses API format.
-- Returns: instructions (string), input (array)
-- - System messages are concatenated into `instructions`
-- - User/assistant messages become the `input` array
local function messages_to_codex(messages)
    if type(messages) ~= "table" then return nil, {} end

    local system_parts = {}
    local input_parts = {}

    for _, msg in ipairs(messages) do
        local role = msg.role or "user"
        local content = msg.content

        if role == "system" or role == "developer" then
            -- System / developer messages go into instructions
            local text = extract_text_content(content)
            if text ~= "" then
                table.insert(system_parts, text)
            end
        elseif type(content) == "string" then
            table.insert(input_parts, {
                role = role,
                content = {
                    { type = (role == "assistant") and "output_text" or "input_text", text = content },
                },
            })
        elseif type(content) == "table" then
            local converted = {}
            for _, part in ipairs(content) do
                if type(part) == "table" then
                    if part.type == "text" and part.text then
                        table.insert(converted, {
                            type = (role == "assistant") and "output_text" or "input_text",
                            text = part.text,
                        })
                    elseif part.type == "image_url" and part.image_url then
                        local url = type(part.image_url) == "table" and part.image_url.url or part.image_url
                        table.insert(converted, {
                            type = "input_image",
                            image_url = url,
                        })
                    end
                end
            end
            if #converted > 0 then
                table.insert(input_parts, { role = role, content = converted })
            end
        end
    end

    local instructions = #system_parts > 0 and table.concat(system_parts, "\n\n") or nil
    return instructions, input_parts
end


-- Fallback instruction when client doesn't provide a system message.
-- Codex API rejects requests without `instructions`.
local DEFAULT_INSTRUCTIONS = "You are a helpful AI assistant."


-- Flatten OpenAI Chat Completions tool format to Codex Responses flat format.
-- OpenAI:  {"type":"function","function":{"name":"...","parameters":{...}}}
-- Codex:   {"type":"function","name":"...","parameters":{...}}
local function normalize_tools(tools)
    if type(tools) ~= "table" then
        return tools
    end

    local normalized = {}
    for _, tool in ipairs(tools) do
        if type(tool) == "table" and tool.type == "function"
                and type(tool["function"]) == "table" and not tool.name then
            table.insert(normalized, {
                type = "function",
                name = tool["function"].name,
                description = tool["function"].description,
                parameters = tool["function"].parameters,
                strict = tool["function"].strict,
            })
        else
            table.insert(normalized, tool)
        end
    end

    return normalized
end


-- Normalize tool_choice to Codex flat format.
-- OpenAI: {"type":"function","function":{"name":"..."}}
-- Codex:  {"type":"function","name":"..."}
local function normalize_tool_choice(tc)
    if type(tc) == "table" and tc.type == "function"
            and type(tc["function"]) == "table" and not tc.name then
        return {
            type = "function",
            name = tc["function"].name,
        }
    end
    return tc
end


local function translate_request(body)
    local instructions, input = messages_to_codex(body.messages)
    local out = {
        model = body.model,
        instructions = instructions or DEFAULT_INSTRUCTIONS,
        input = input,
        stream = true,                -- Codex REQUIRES stream=true; we aggregate
                                      -- internally if client wanted non-stream
        -- Codex required/expected fields:
        store = false,                -- required: Codex rejects store=true
        parallel_tool_calls = false,  -- expected by Codex CLI requests
    }

    if body.max_tokens then out.max_output_tokens = body.max_tokens end
    if body.max_completion_tokens then out.max_output_tokens = body.max_completion_tokens end
    if body.temperature then out.temperature = body.temperature end
    if body.top_p then out.top_p = body.top_p end
    if body.stop then out.stop = body.stop end
    if body.user then out.user = body.user end

    -- Reasoning / tools pass-through
    if body.reasoning_effort then
        out.reasoning = { effort = body.reasoning_effort }
    end
    if body.tools and #body.tools > 0 then
        out.tools = normalize_tools(body.tools)
        if body.parallel_tool_calls ~= nil then
            out.parallel_tool_calls = body.parallel_tool_calls
        else
            out.parallel_tool_calls = true  -- when tools present, default to true
        end
    end
    if body.tool_choice then out.tool_choice = normalize_tool_choice(body.tool_choice) end

    -- Response format
    if body.response_format then
        if body.response_format.type == "json_object" then
            out.text = { format = { type = "json_object" } }
        elseif body.response_format.type == "json_schema" then
            out.text = { format = body.response_format }
        end
    end

    return out
end


-- ============================================================
-- Response translation: Codex Responses -> OpenAI Chat Completions
-- ============================================================

local function extract_text_from_output(output)
    if type(output) ~= "table" then return "" end
    local parts = {}
    for _, item in ipairs(output) do
        if type(item) == "table" and item.type == "message" and type(item.content) == "table" then
            for _, c in ipairs(item.content) do
                if type(c) == "table" and (c.type == "output_text" or c.type == "text") then
                    if type(c.text) == "string" then
                        table.insert(parts, c.text)
                    end
                end
            end
        end
    end
    return table.concat(parts, "")
end


local function codex_usage_to_openai(usage)
    if type(usage) ~= "table" then return nil end
    local input_tokens = usage.input_tokens or 0
    local output_tokens = usage.output_tokens or 0
    local details = usage.input_tokens_details or {}
    local cached_tokens = details.cached_tokens or 0
    return {
        prompt_tokens = input_tokens,
        completion_tokens = output_tokens,
        total_tokens = input_tokens + output_tokens,
        prompt_tokens_details = { cached_tokens = cached_tokens },
    }
end


local function translate_response(body, model)
    local text = ""
    if type(body.output_text) == "string" and body.output_text ~= "" then
        text = body.output_text
    else
        text = extract_text_from_output(body.output)
    end

    local finish_reason = "stop"
    if body.status == "incomplete" then
        finish_reason = body.incomplete_details and body.incomplete_details.reason or "length"
        if finish_reason == "max_output_tokens" then finish_reason = "length" end
    end

    return {
        id = body.id or "chatcmpl-codex",
        object = "chat.completion",
        created = body.created_at or ngx_time(),
        model = body.model or model or "",
        choices = {
            {
                index = 0,
                message = {
                    role = "assistant",
                    content = text,
                },
                finish_reason = finish_reason,
            },
        },
        usage = codex_usage_to_openai(body.usage) or {
            prompt_tokens = 0, completion_tokens = 0, total_tokens = 0,
        },
    }
end


local function make_stream_chunk(id, model, delta_content, finish_reason, usage)
    local choice = {
        index = 0,
        delta = {},
        finish_reason = finish_reason,
    }
    if delta_content then
        choice.delta.content = delta_content
    end
    if finish_reason == nil and delta_content == nil then
        choice.delta.role = "assistant"
    end

    local chunk = {
        id = id,
        object = "chat.completion.chunk",
        created = ngx_time(),
        model = model,
        choices = { choice },
    }
    if usage then chunk.usage = usage end
    return "data: " .. core.json.encode(chunk) .. "\n\n"
end


-- Detect SSE-looking payload even when Content-Type is missing/wrong.
local function looks_like_sse_payload(body)
    if type(body) ~= "string" then return false end
    local trimmed = body:gsub("^%s+", "")
    return core.string.has_prefix(trimmed, "event:")
        or core.string.has_prefix(trimmed, "data:")
end


-- Extract function calls from Codex response.output[] and translate to OpenAI tool_calls.
local function extract_tool_calls(output)
    if type(output) ~= "table" then return nil end
    local calls = {}
    for _, item in ipairs(output) do
        if type(item) == "table" and item.type == "function_call" then
            table.insert(calls, {
                id = item.call_id or item.id or ("call_" .. #calls),
                type = "function",
                ["function"] = {
                    name = item.name,
                    arguments = item.arguments or "{}",
                },
            })
        end
    end
    return #calls > 0 and calls or nil
end


-- Process a single Codex SSE event.
--   Updates stream_state (content, tool_calls, usage)
--   Returns translated OpenAI chat.completion.chunk SSE text (or nil)
local function translate_sse_event(ctx, stream_state, event)
    local data = event.data
    if not data or data == "" or data == "[DONE]" then
        return nil
    end

    local json_data = core.json.decode(data)
    if not json_data then
        return nil
    end

    local ev_type = json_data.type or event.type

    -- Aggregate text deltas (for streaming clients)
    if ev_type == "response.output_text.delta" then
        local delta = json_data.delta
        if type(delta) == "string" and delta ~= "" then
            stream_state.content_parts = stream_state.content_parts or {}
            table.insert(stream_state.content_parts, delta)
            return make_stream_chunk(stream_state.id, stream_state.model, delta, nil, nil)
        end

    -- Final event: contains the full assembled response. This is the source
    -- of truth for both content and usage.
    elseif ev_type == "response.completed" then
        local response = json_data.response or {}
        local usage = codex_usage_to_openai(response.usage)
        if usage then
            ctx.ai_token_usage = {
                prompt_tokens = usage.prompt_tokens,
                completion_tokens = usage.completion_tokens,
                total_tokens = usage.total_tokens,
            }
            ctx.var.llm_prompt_tokens = usage.prompt_tokens
            ctx.var.llm_completion_tokens = usage.completion_tokens
        end

        -- Extract full text from response.output (authoritative source)
        local full_text = ""
        if type(response.output_text) == "string" and response.output_text ~= "" then
            full_text = response.output_text
        else
            full_text = extract_text_from_output(response.output)
        end

        -- How much content was already sent as deltas
        local aggregated = table.concat(stream_state.content_parts or {}, "")
        local missing_content = ""
        if full_text ~= "" and #full_text > #aggregated then
            -- Content is missing from the streamed deltas (e.g. reasoning models
            -- where output_text.delta events weren't emitted). Use the full
            -- authoritative text and compute what still needs to be sent.
            if aggregated == "" then
                missing_content = full_text
            else
                -- Best-effort: send difference. In practice full_text usually
                -- either matches aggregated exactly or deltas were empty.
                missing_content = full_text:sub(#aggregated + 1)
            end
            stream_state.content_parts = { full_text }
        end

        -- Extract tool calls
        stream_state.tool_calls = extract_tool_calls(response.output)

        local finish = "stop"
        if response.status == "incomplete" then finish = "length" end
        if stream_state.tool_calls then finish = "tool_calls" end

        stream_state.finish_reason = finish
        stream_state.usage = usage
        stream_state.completed = true

        local parts_out = {}
        -- Emit a content-delta chunk with any missing text BEFORE the final chunk
        if missing_content ~= "" then
            table.insert(parts_out, make_stream_chunk(
                stream_state.id, stream_state.model, missing_content, nil, nil))
        end

        -- If there are tool calls, emit them as delta chunks (OpenAI format)
        if stream_state.tool_calls then
            for i, tc in ipairs(stream_state.tool_calls) do
                local tc_chunk = {
                    id = stream_state.id,
                    object = "chat.completion.chunk",
                    created = ngx_time(),
                    model = stream_state.model,
                    choices = {
                        {
                            index = 0,
                            delta = {
                                tool_calls = { {
                                    index = i - 1,
                                    id = tc.id,
                                    type = "function",
                                    ["function"] = {
                                        name = tc["function"].name,
                                        arguments = tc["function"].arguments,
                                    },
                                } },
                            },
                            finish_reason = nil,
                        },
                    },
                }
                table.insert(parts_out, "data: " .. core.json.encode(tc_chunk) .. "\n\n")
            end
        end

        table.insert(parts_out,
            make_stream_chunk(stream_state.id, stream_state.model, nil, finish, usage))
        table.insert(parts_out, "data: [DONE]\n\n")
        return table.concat(parts_out, "")

    elseif ev_type == "response.failed" or ev_type == "error" then
        core.log.warn("codex-compat stream error event: ", data)
        stream_state.failed = true
    end

    -- Log unusual events for debugging
    if ev_type and ev_type ~= "response.output_text.delta"
            and ev_type ~= "response.completed"
            and ev_type ~= "response.created"
            and ev_type ~= "response.in_progress" then
        core.log.info("codex-compat unhandled event type: ", ev_type)
    end

    return nil
end


-- Build a final non-stream OpenAI chat.completion response from aggregated stream state.
local function build_aggregated_response(stream_state, model)
    local content = table.concat(stream_state.content_parts or {}, "")
    local usage = stream_state.usage or {
        prompt_tokens = 0, completion_tokens = 0, total_tokens = 0,
    }

    local message = {
        role = "assistant",
        -- OpenAI spec: content may be null when tool_calls present, but most
        -- clients prefer empty string over null. Keep string.
        content = content,
    }
    if stream_state.tool_calls then
        message.tool_calls = stream_state.tool_calls
    end

    core.log.info("codex-compat aggregated response: content_len=", #content,
                  ", tool_calls=", stream_state.tool_calls and #stream_state.tool_calls or 0,
                  ", finish=", stream_state.finish_reason or "stop")

    return {
        id = stream_state.id,
        object = "chat.completion",
        created = ngx_time(),
        model = model,
        choices = {
            {
                index = 0,
                message = message,
                finish_reason = stream_state.finish_reason or "stop",
            },
        },
        usage = usage,
    }
end


-- Buffered SSE decoder: accumulates partial events across chunks.
-- Returns (events_list, leftover_string).
local function decode_buffered_sse(stream_state, chunk)
    local buffer = (stream_state.pending_sse or "") .. (chunk or "")
    -- SSE event boundary is a blank line ("\n\n")
    local last_boundary = buffer:match("()\n\n[^\n]*$") or buffer:match("()\n\n$")

    local complete_part
    if last_boundary then
        complete_part = buffer:sub(1, last_boundary + 1)  -- include the \n\n
        stream_state.pending_sse = buffer:sub(last_boundary + 2)
    else
        complete_part = ""
        stream_state.pending_sse = buffer
    end

    if complete_part == "" then return {} end
    return sse.decode(complete_part)
end


local function read_response(conf, ctx, res, model)
    local content_type = res.headers["Content-Type"] or res.headers["content-type"] or ""
    core.log.info("codex-compat response content-type: ", content_type,
                  " status: ", res.status)

    local client_wants_stream = ctx.codex_compat_client_stream == true
    local stream_state = {
        id = "chatcmpl-codex-" .. ngx_time(),
        model = model,
        pending_sse = "",
        content_parts = {},
    }

    -- === Streaming response (SSE from upstream) ===
    if content_type and core.string.find(content_type, "text/event-stream") then
        local body_reader = res.body_reader
        if not body_reader then
            core.log.warn("codex-compat: no body_reader for SSE response")
            return HTTP_INTERNAL_SERVER_ERROR
        end

        if client_wants_stream then
            core.response.set_header("Content-Type", "text/event-stream")
            core.response.set_header("Cache-Control", "no-cache")
            -- Initial chunk with assistant role
            local init_chunk = make_stream_chunk(stream_state.id, model, nil, nil, nil)
            plugin.lua_response_filter(ctx, res.headers, init_chunk)
        end
        -- else: silently aggregate, emit single JSON at the end

        while true do
            local chunk, err = body_reader()
            ctx.var.apisix_upstream_response_time =
                math.floor((ngx_now() - ctx.llm_request_start_time) * 1000)
            if err then
                core.log.warn("codex-compat failed to read chunk: ", err)
                return handle_error(err)
            end
            if not chunk then
                -- Flush trailing partial event
                if stream_state.pending_sse and stream_state.pending_sse ~= "" then
                    local trailing = sse.decode(stream_state.pending_sse .. "\n\n")
                    local parts = {}
                    for _, event in ipairs(trailing) do
                        local translated = translate_sse_event(ctx, stream_state, event)
                        if translated and client_wants_stream then
                            table.insert(parts, translated)
                        end
                    end
                    if client_wants_stream and #parts > 0 then
                        plugin.lua_response_filter(ctx, res.headers, table.concat(parts, ""))
                    end
                end

                -- If client wanted non-stream, emit the aggregated JSON now
                if not client_wants_stream then
                    core.response.set_header("Content-Type", "application/json")
                    local aggregated = build_aggregated_response(stream_state, model)
                    ctx.var.llm_response_text = aggregated.choices[1].message.content
                    local out_json = core.json.encode(aggregated)
                    plugin.lua_response_filter(ctx, res.headers, out_json)
                end
                return
            end

            if ctx.var.llm_time_to_first_token == "0" then
                ctx.var.llm_time_to_first_token =
                    math.floor((ngx_now() - ctx.llm_request_start_time) * 1000)
            end

            local events = decode_buffered_sse(stream_state, chunk)
            local parts = {}
            for _, event in ipairs(events) do
                local translated = translate_sse_event(ctx, stream_state, event)
                if translated and client_wants_stream then
                    table.insert(parts, translated)
                end
            end
            if client_wants_stream and #parts > 0 then
                plugin.lua_response_filter(ctx, res.headers, table.concat(parts, ""))
            end
        end
    end

    -- === Non-streaming response ===
    local raw_res_body, err = res:read_body()
    if not raw_res_body then
        core.log.warn("codex-compat failed to read body: ", err)
        return handle_error(err)
    end

    ngx.status = res.status
    ctx.var.llm_time_to_first_token = math.floor((ngx_now() - ctx.llm_request_start_time) * 1000)
    ctx.var.apisix_upstream_response_time = ctx.var.llm_time_to_first_token

    local body = core.json.decode(raw_res_body)
    if not body then
        -- Fallback: SSE returned without event-stream Content-Type
        if looks_like_sse_payload(raw_res_body) then
            core.log.info("codex-compat: SSE payload without event-stream content-type")
            local events = sse.decode(raw_res_body)
            local parts = {}
            for _, event in ipairs(events) do
                local translated = translate_sse_event(ctx, stream_state, event)
                if translated and client_wants_stream then
                    table.insert(parts, translated)
                end
            end

            if client_wants_stream then
                core.response.set_header("Content-Type", "text/event-stream")
                core.response.set_header("Cache-Control", "no-cache")
                local init_chunk = make_stream_chunk(stream_state.id, model, nil, nil, nil)
                plugin.lua_response_filter(ctx, res.headers, init_chunk .. table.concat(parts, ""))
            else
                core.response.set_header("Content-Type", "application/json")
                local aggregated = build_aggregated_response(stream_state, model)
                ctx.var.llm_response_text = aggregated.choices[1].message.content
                plugin.lua_response_filter(ctx, res.headers, core.json.encode(aggregated))
            end
            return
        end

        core.log.warn("codex-compat: invalid response body: ",
                      raw_res_body and raw_res_body:sub(1, 300) or "nil",
                      " err: ", err or "nil")
        core.response.set_header("Content-Type", "application/json")
        plugin.lua_response_filter(ctx, res.headers, raw_res_body or "")
        return
    end

    if res.status >= 400 then
        core.response.set_header("Content-Type", "application/json")
        plugin.lua_response_filter(ctx, res.headers, raw_res_body)
        return
    end

    if body.usage then
        local openai_usage = codex_usage_to_openai(body.usage)
        if openai_usage then
            ctx.ai_token_usage = {
                prompt_tokens = openai_usage.prompt_tokens,
                completion_tokens = openai_usage.completion_tokens,
                total_tokens = openai_usage.total_tokens,
            }
            ctx.var.llm_prompt_tokens = openai_usage.prompt_tokens
            ctx.var.llm_completion_tokens = openai_usage.completion_tokens
        end
    end

    local openai_resp = translate_response(body, model)
    if openai_resp.choices and openai_resp.choices[1] then
        ctx.var.llm_response_text = openai_resp.choices[1].message.content or ""
    end

    core.response.set_header("Content-Type", "application/json")
    local out_json, jerr = core.json.encode(openai_resp)
    if not out_json then
        core.log.error("codex-compat encode response failed: ", jerr)
        return HTTP_INTERNAL_SERVER_ERROR
    end
    plugin.lua_response_filter(ctx, res.headers, out_json)
end


function _M.validate_request(ctx)
    local ct = core.request.header(ctx, "Content-Type") or CONTENT_TYPE_JSON
    if not core.string.has_prefix(ct, CONTENT_TYPE_JSON) then
        return nil, "unsupported content-type: " .. ct
    end
    local body, err = core.request.get_json_request_body_table()
    if not body then return nil, err end
    if type(body.messages) ~= "table" then
        return nil, "invalid request: 'messages' field is required"
    end
    return body, nil
end


function _M.request(self, ctx, conf, request_table, extra_opts)
    local httpc = http.new()
    httpc:set_timeout(conf.timeout or 30000)

    local auth = extra_opts.auth or {}
    local access_token, err = resolve_access_token(auth, ctx)
    if not access_token then
        return 401, "unauthorized: " .. (err or "no token")
    end

    -- Translate request body: OpenAI -> Codex Responses format
    local model = request_table.model or "gpt-4o"
    if extra_opts.model_options and extra_opts.model_options.model then
        model = extra_opts.model_options.model
    end
    ctx.var.llm_model = model
    request_table.model = model

    -- Remember whether the CLIENT asked for streaming.
    -- Codex upstream ALWAYS requires stream=true, so we force it on and
    -- aggregate chunks internally when the client wants a non-stream response.
    local client_wants_stream = request_table.stream == true
    ctx.codex_compat_client_stream = client_wants_stream

    local codex_body = translate_request(request_table)

    -- Determine target endpoint (override or default)
    local host = DEFAULT_HOST
    local path = DEFAULT_PATH
    local scheme = "https"
    local port = 443
    if extra_opts.endpoint then
        local url = require("socket.url")
        local parsed = url.parse(extra_opts.endpoint)
        if parsed then
            host = parsed.host or host
            path = parsed.path or path
            scheme = parsed.scheme or scheme
            port = parsed.port or port
        end
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. access_token,
        ["Accept"] = "text/event-stream",
        ["User-Agent"] = "codex_cli_rs/0.8.0",
        ["OpenAI-Beta"] = "responses=experimental",
        ["Originator"] = "codex_cli_rs",
    }
    if auth.oauth and auth.oauth.account_id then
        headers["ChatGPT-Account-Id"] = auth.oauth.account_id
    end
    -- Copy extra auth headers (except Authorization which we set)
    if auth.header then
        for k, v in pairs(auth.header) do
            if k ~= "Authorization" then headers[k] = v end
        end
    end

    local params = {
        method = "POST",
        scheme = scheme,
        path = path,
        host = host,
        port = port,
        headers = headers,
        ssl_verify = conf.ssl_verify ~= false,
        ssl_server_name = host,
    }

    local proxy_opts = build_proxy_opts()
    if proxy_opts then httpc:set_proxy_options(proxy_opts) end

    local ok, err = httpc:connect(params)
    if not ok then
        core.log.error("codex-compat connect failed: ", err)
        return handle_error(err)
    end

    local req_json, jerr = core.json.encode(codex_body)
    if not req_json then return 500, "encode failed: " .. (jerr or "") end
    params.body = req_json

    core.log.info("codex-compat sending to ", host, path, " model=", model,
                  " stream=", tostring(codex_body.stream),
                  " body=", req_json)

    local res, err = httpc:request(params)
    if not res then
        core.log.warn("codex-compat request failed: ", err)
        return handle_error(err)
    end

    if res.status >= 400 and res.status < 500 and res.status ~= 401 then
        -- 4xx errors: log full response body + headers for debugging
        local errbody = res:read_body() or ""
        core.log.warn("codex-compat upstream ", res.status, " error")
        core.log.warn("  headers: ", core.json.encode(res.headers or {}))
        core.log.warn("  body: ", errbody)
        ngx.status = res.status
        core.response.set_header("Content-Type", "application/json")
        plugin.lua_response_filter(ctx, res.headers, errbody)
        return
    end

    if res.status == 429 or (res.status >= 500 and res.status < 600) then
        local errbody = res:read_body() or ""
        core.log.warn("codex-compat upstream error ", res.status, ": ", errbody)
        return res.status
    end

    local code, body = read_response(conf, ctx, res, model)

    if conf.keepalive ~= false then
        httpc:set_keepalive(conf.keepalive_timeout or 60000, conf.keepalive_pool or 30)
    end
    return code, body
end


return _M
