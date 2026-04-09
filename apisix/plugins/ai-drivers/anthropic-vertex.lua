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
-- Anthropic Claude on Google Vertex AI
-- Endpoint: https://aiplatform.googleapis.com/v1/projects/{PROJECT_ID}/locations/{REGION}/publishers/anthropic/models/{MODEL}:rawPredict
-- API format: Anthropic native Messages API (not OpenAI compatible)
-- Auth: GCP OAuth (service account)

local core = require("apisix.core")
local http = require("resty.http")
local sse  = require("apisix.plugins.ai-drivers.sse")
local plugin = require("apisix.plugin")
local google_oauth = require("apisix.utils.google-cloud-oauth")
local lrucache = require("resty.lrucache")
local proxy_utils = require("apisix.plugins.ai-drivers.proxy-utils")

local ngx = ngx
local ngx_now = ngx.now
local ipairs = ipairs
local type = type
local table = table
local math = math
local string = string
local os = os

local _M = {}

local CONTENT_TYPE_JSON = "application/json"
local VERTEX_ANTHROPIC_VERSION = "vertex-2023-10-16"

local HTTP_INTERNAL_SERVER_ERROR = ngx.HTTP_INTERNAL_SERVER_ERROR
local HTTP_GATEWAY_TIMEOUT = ngx.HTTP_GATEWAY_TIMEOUT

-- Path template: /v1/projects/{PROJECT_ID}/locations/{REGION}/publishers/anthropic/models/{MODEL}:{ACTION}
local PATH_FMT = "/v1/projects/%s/locations/%s/publishers/anthropic/models/%s:%s"

local build_proxy_opts = proxy_utils.build_proxy_opts


local function handle_error(err)
    if core.string.find(err, "timeout") then
        return HTTP_GATEWAY_TIMEOUT
    end
    return HTTP_INTERNAL_SERVER_ERROR
end


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


local function merge_usage(existing, incoming)
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
                                apply_usage_to_ctx(ctx, json_data.message.usage)
                            end
                        elseif event_type == "content_block_delta" then
                            if json_data.delta and json_data.delta.type == "text_delta" then
                                local text = json_data.delta.text or ""
                                table.insert(contents, text)
                            end
                        elseif event_type == "message_delta" then
                            if json_data.usage then
                                local merged = merge_usage(ctx.llm_raw_usage, json_data.usage)
                                apply_usage_to_ctx(ctx, merged)
                            end
                        elseif event_type == "message_stop" then
                            ctx.var.llm_request_done = true
                            ctx.var.llm_response_text = table.concat(contents, "")
                        end
                    end
                end
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
        core.log.warn("invalid response body: ", raw_res_body, " err: ", err)
        plugin.lua_response_filter(ctx, res.headers, raw_res_body)
        return
    end

    if res_body.usage then
        apply_usage_to_ctx(ctx, res_body.usage)
    end

    if type(res_body.content) == "table" and #res_body.content > 0 then
        local text_parts = {}
        for _, block in ipairs(res_body.content) do
            if block.type == "text" then
                table.insert(text_parts, block.text or "")
            end
        end
        ctx.var.llm_response_text = table.concat(text_parts, "")
    end

    plugin.lua_response_filter(ctx, res.headers, raw_res_body)
end


function _M.validate_request(ctx)
    local ct = core.request.header(ctx, "Content-Type") or CONTENT_TYPE_JSON
    if not core.string.has_prefix(ct, CONTENT_TYPE_JSON) then
        return nil, "unsupported content-type: " .. ct
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

    local auth_conf = {}
    local service_account_json = gcp_conf.service_account_json or
                                    os.getenv("GCP_SERVICE_ACCOUNT")
    core.log.info("gcp auth: from config: ",
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
    return access_token
end


function _M.request(self, ctx, conf, request_table, extra_opts)
    local httpc, err = http.new()
    if not httpc then
        core.log.error("failed to create http client: ", err)
        return HTTP_INTERNAL_SERVER_ERROR
    end
    httpc:set_timeout(conf.timeout)

    -- Get GCP access token
    local auth = extra_opts.auth or {}
    if not auth.gcp then
        core.log.error("anthropic-vertex requires auth.gcp configuration")
        return 500, "missing GCP auth configuration"
    end

    local token, err = fetch_gcp_access_token(ctx, extra_opts.name, auth.gcp)
    if not token then
        core.log.error("failed to get gcp access token: ", err)
        return 500, err
    end

    -- Get provider_conf (project_id, region)
    local vertex_conf = extra_opts.conf or {}
    local project_id = vertex_conf.project_id
    local region = vertex_conf.region or "global"

    if not project_id then
        core.log.error("anthropic-vertex requires provider_conf.project_id")
        return 500, "missing project_id"
    end

    -- Resolve model: config > request body > default
    local model = "claude-sonnet-4-6"
    if extra_opts.model_options and extra_opts.model_options.model then
        model = extra_opts.model_options.model
    elseif request_table.model then
        model = request_table.model
    end
    ctx.var.llm_model = model

    -- Build Vertex AI path
    local is_stream = request_table.stream or false
    local action = is_stream and "streamRawPredict" or "rawPredict"
    local path = string.format(PATH_FMT, project_id, region, model, action)
    local host = "aiplatform.googleapis.com"

    -- Build Anthropic request body (remove model, add anthropic_version)
    request_table.model = nil
    request_table.anthropic_version = VERTEX_ANTHROPIC_VERSION

    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. token,
    }

    local params = {
        method = "POST",
        scheme = "https",
        headers = headers,
        ssl_verify = conf.ssl_verify,
        path = path,
        host = host,
        port = 443,
        ssl_server_name = host,
    }
    params.body = request_table

    -- Set proxy if configured
    local proxy_opts = build_proxy_opts()
    if proxy_opts then
        httpc:set_proxy_options(proxy_opts)
    end

    core.log.info("sending request to Vertex AI Anthropic: ",
                  host, path, ", model: ", model, ", stream: ", is_stream)

    local ok, err = httpc:connect(params)
    if not ok then
        core.log.error("failed to connect to Vertex AI: ", err)
        return handle_error(err)
    end

    local req_json, err = core.json.encode(params.body)
    if not req_json then
        return 500, "failed to encode request body: " .. (err or "unknown error")
    end
    params.body = req_json

    local res, err = httpc:request(params)
    if not res then
        core.log.warn("failed to send request to Vertex AI: ", err)
        return handle_error(err)
    end

    if res.status == 429 or (res.status >= 500 and res.status < 600) then
        local err_body = res:read_body()
        core.log.warn("Vertex AI returned error: ", res.status, ", body: ", err_body or "")
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
