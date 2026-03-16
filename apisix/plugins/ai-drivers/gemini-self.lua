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
local table = table
local math = math
local setmetatable = setmetatable
local string = string
local os = os

local _M = {}
local mt = { __index = _M }

local CONTENT_TYPE_JSON = "application/json"

local HTTP_INTERNAL_SERVER_ERROR = ngx.HTTP_INTERNAL_SERVER_ERROR
local HTTP_GATEWAY_TIMEOUT = ngx.HTTP_GATEWAY_TIMEOUT

function _M.new(opt)
    local self = setmetatable(opt or {}, mt)
    self.host = self.host or "generativelanguage.googleapis.com"
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

local function normalize_usage(usage)
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

local function transform_openai_to_gemini(request_table)
    local model = request_table.model or "gemini-pro"
    model = model:gsub("^gemini%-", "gemini-")

    local gemini_request = {
        contents = {},
        generationConfig = {}
    }

    local system_content = nil
    local messages = request_table.messages or {}

    for _, msg in ipairs(messages) do
        if msg.role == "system" then
            system_content = msg.content
        else
            local gemini_role = "user"
            if msg.role == "assistant" then
                gemini_role = "model"
            end

            local content_item = {
                role = gemini_role,
                parts = {
                    { text = msg.content }
                }
            }
            table.insert(gemini_request.contents, content_item)
        end
    end

    if system_content then
        gemini_request.systemInstruction = {
            parts = {
                { text = system_content }
            }
        }
    end

    local gen_config = gemini_request.generationConfig

    if request_table.max_tokens then
        gen_config.maxOutputTokens = request_table.max_tokens
    end
    if request_table.temperature then
        gen_config.temperature = request_table.temperature
    end
    if request_table.top_p then
        gen_config.topP = request_table.top_p
    end
    if request_table.top_k then
        gen_config.topK = request_table.top_k
    end
    if request_table.stop then
        if type(request_table.stop) == "table" then
            gen_config.stopSequences = request_table.stop
        else
            gen_config.stopSequences = { request_table.stop }
        end
    end

    return model, gemini_request
end

local function transform_gemini_to_openai(response_body, model)
    local openai_response = {
        id = "gemini-" .. ngx.time(),
        object = "chat.completion",
        created = ngx.time(),
        model = model,
        choices = {},
        usage = nil
    }

    if type(response_body.candidates) == "table" and #response_body.candidates > 0 then
        local candidate = response_body.candidates[1]
        local text_content = ""

        if type(candidate.content) == "table" and
           type(candidate.content.parts) == "table" then
            for _, part in ipairs(candidate.content.parts) do
                if part.text then
                    text_content = text_content .. part.text
                end
            end
        end

        local finish_reason = "stop"
        if candidate.finishReason then
            local reason_map = {
                STOP = "stop",
                MAX_TOKENS = "length",
                SAFETY = "content_filter",
                RECITATION = "content_filter",
                OTHER = "stop"
            }
            finish_reason = reason_map[candidate.finishReason] or "stop"
        end

        openai_response.choices = {
            {
                index = 0,
                message = {
                    role = "assistant",
                    content = text_content
                },
                finish_reason = finish_reason
            }
        }
    end

    if response_body.usageMetadata then
        openai_response.usage = {
            prompt_tokens = response_body.usageMetadata.promptTokenCount or 0,
            completion_tokens = response_body.usageMetadata.candidatesTokenCount or 0,
            total_tokens = response_body.usageMetadata.totalTokenCount or 0
        }
    end

    return openai_response
end

local function read_response(conf, ctx, res, model)
    local body_reader = res.body_reader
    if not body_reader then
        core.log.warn("AI service sent no response body")
        return HTTP_INTERNAL_SERVER_ERROR
    end

    local content_type = res.headers["Content-Type"]
    core.response.set_header("Content-Type", content_type)
    core.log.info("got token usage from ai service content_type: ", content_type)

    if content_type and core.string.find(content_type, "text/event-stream") then
        local current_content = ""
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
            -- local response_chunks = {}
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
                    local normalized = normalize_usage(json_data.usageMetadata)
                    if normalized then
                        ctx.ai_token_usage = normalized
                        ctx.var.llm_prompt_tokens = normalized.prompt_tokens
                        ctx.var.llm_completion_tokens = normalized.completion_tokens
                    end
                end

                -- if type(json_data.candidates) == "table" and #json_data.candidates > 0 then
                --     local candidate = json_data.candidates[1]

                --     if type(candidate.content) == "table" and
                --        type(candidate.content.parts) == "table" then
                --         for _, part in ipairs(candidate.content.parts) do
                --             if part.text then
                --                 current_content = current_content .. part.text

                --                 local openai_chunk = {
                --                     id = json_data.responseId or "gemini-stream",
                --                     object = "chat.completion.chunk",
                --                     created = ngx.time(),
                --                     model = model,
                --                     choices = {
                --                         {
                --                             index = 0,
                --                             delta = {
                --                                 content = part.text
                --                             },
                --                             finish_reason = nil
                --                         }
                --                     }
                --                 }
                --                 local chunk_json = core.json.encode(openai_chunk)
                --                 table.insert(response_chunks, "data: " .. chunk_json .. "\n\n")
                --             end
                --         end
                --     end

                --     if candidate.finishReason and candidate.finishReason ~= "" then
                --         local finish_reason = "stop"
                --         local reason_map = {
                --             STOP = "stop",
                --             MAX_TOKENS = "length",
                --             SAFETY = "content_filter",
                --             RECITATION = "content_filter"
                --         }
                --         finish_reason = reason_map[candidate.finishReason] or "stop"

                --         local done_chunk = {
                --             id = json_data.responseId or "gemini-stream",
                --             object = "chat.completion.chunk",
                --             created = ngx.time(),
                --             model = model,
                --             choices = {
                --                 {
                --                     index = 0,
                --                     delta = {},
                --                     finish_reason = finish_reason
                --                 }
                --             }
                --         }
                --         local chunk_json = core.json.encode(done_chunk)
                --         table.insert(response_chunks, "data: " .. chunk_json .. "\n\n")
                --         table.insert(response_chunks, "data: [DONE]\n\n")
                --         ctx.var.llm_request_done = true
                --         ctx.var.llm_response_text = current_content
                --     end
                -- end

                ::CONTINUE::
            end
            plugin.lua_response_filter(ctx, res.headers, chunk)
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

    if res_body.usageMetadata then
        ctx.llm_raw_usage = res_body.usageMetadata
        local normalized = normalize_usage(res_body.usageMetadata)
        if normalized then
            ctx.ai_token_usage = normalized
            ctx.var.llm_prompt_tokens = normalized.prompt_tokens
            ctx.var.llm_completion_tokens = normalized.completion_tokens
        end
    end

    local openai_response = transform_gemini_to_openai(res_body, model)

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

    local model, gemini_request = transform_openai_to_gemini(request_table)

    if extra_opts.model_options then
        for opt, val in pairs(extra_opts.model_options) do
            request_table[opt] = val
        end
    end

    local auth = extra_opts.auth or {}
    local query_params = auth.query or {}
    if type(parsed_url) == "table" and parsed_url.query and #parsed_url.query > 0 then
        local args_tab = core.string.decode_args(parsed_url.query)
        if type(args_tab) == "table" then
            core.table.merge(query_params, args_tab)
        end
    end

    local api_key
    local headers = auth.header or {}
    headers["Content-Type"] = "application/json"

    if auth.header and auth.header["Authorization"] then
        local auth_header = auth.header["Authorization"]
        if auth_header:match("^Bearer%s+(.+)$") then
            api_key = auth_header:match("^Bearer%s+(.+)$")
        end
    end

    if api_key then
        query_params.key = api_key
    end

    local is_stream = request_table.stream or false
    local api_path
    if is_stream then
        api_path = "/v1beta/models/" .. model .. ":streamGenerateContent?alt=sse"
    else
        api_path = "/v1beta/models/" .. model .. ":generateContent"
    end

    local path = (parsed_url and parsed_url.path) or api_path

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

    params.body = gemini_request

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

    local code, body = read_response(conf, ctx, res, model)

    if conf.keepalive then
        local ok, err = httpc:set_keepalive(conf.keepalive_timeout, conf.keepalive_pool)
        if not ok then
            core.log.warn("failed to keepalive connection: ", err)
        end
    end

    return code, body
end

return _M
