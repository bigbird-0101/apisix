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
local require = require
local setmetatable = setmetatable
local ipairs = ipairs
local type = type
local core = require("apisix.core")
local limit_count = require("apisix.plugins.limit-count.init")
local lrucache = require("resty.lrucache")

local plugin_name = "ai-rate-limiting"

local DEFAULT_MODEL_PRICES = {
    -- Anthropic Claude
    ["claude-opus-4-6"] = {
        prompt_price_per_million = 5.0,
        cached_prompt_price_per_million = 0.5,
        cache_creation_5m_prompt_price_per_million = 6.25,
        cache_creation_1h_prompt_price_per_million = 10.0,
        prompt_token_threshold = 200000,
        prompt_price_per_million_above_threshold = 10.0,
        cached_prompt_price_per_million_above_threshold = 1.0,
        cache_creation_5m_prompt_price_per_million_above_threshold = 12.5,
        cache_creation_1h_prompt_price_per_million_above_threshold = 20.0,
        completion_price_per_million_above_threshold = 37.5,
        completion_price_per_million = 25.0
    },
    ["claude-opus-4"] = {
        prompt_price_per_million = 15.0,
        cached_prompt_price_per_million = 1.5,
        cache_creation_5m_prompt_price_per_million = 18.75,
        cache_creation_1h_prompt_price_per_million = 30.0,
        completion_price_per_million = 75.0
    },
    ["claude-sonnet-4-6"] = {
        prompt_price_per_million = 3.0,
        cached_prompt_price_per_million = 0.3,
        cache_creation_5m_prompt_price_per_million = 3.75,
        cache_creation_1h_prompt_price_per_million = 6.0,
        completion_price_per_million = 15.0
    },
    ["claude-sonnet-4"] = {
        prompt_price_per_million = 3.0,
        completion_price_per_million = 15.0
    },
    ["claude-haiku-4-5"] = {
        prompt_price_per_million = 1.0,
        cached_prompt_price_per_million = 0.1,
        cache_creation_5m_prompt_price_per_million = 1.25,
        cache_creation_1h_prompt_price_per_million = 2.0,
        completion_price_per_million = 5.0
    },
    ["claude-3-5-sonnet"] = {
        prompt_price_per_million = 3.0,
        completion_price_per_million = 15.0
    },
    ["claude-3-opus"] = {
        prompt_price_per_million = 15.0,
        completion_price_per_million = 75.0
    },
    ["claude-3-sonnet"] = {
        prompt_price_per_million = 3.0,
        completion_price_per_million = 15.0
    },
    ["claude-3-haiku"] = {
        prompt_price_per_million = 0.25,
        completion_price_per_million = 1.25
    },
    -- OpenAI
    ["o3"] = {
        prompt_price_per_million = 2.0,
        completion_price_per_million = 8.0
    },
    ["o3-mini"] = {
        prompt_price_per_million = 1.1,
        completion_price_per_million = 4.4
    },
    ["o4-mini"] = {
        prompt_price_per_million = 1.1,
        completion_price_per_million = 4.4
    },
    ["o1"] = {
        prompt_price_per_million = 15.0,
        completion_price_per_million = 60.0
    },
    ["o1-mini"] = {
        prompt_price_per_million = 1.1,
        completion_price_per_million = 4.4
    },
    ["gpt-4o"] = {
        prompt_price_per_million = 2.5,
        cached_prompt_price_per_million = 1.25,
        completion_price_per_million = 10.0
    },
    ["gpt-4o-mini"] = {
        prompt_price_per_million = 0.15,
        cached_prompt_price_per_million = 0.075,
        completion_price_per_million = 0.6
    },
    ["gpt-4.1"] = {
        prompt_price_per_million = 2.0,
        cached_prompt_price_per_million = 0.5,
        completion_price_per_million = 8.0
    },
    ["gpt-4.1-mini"] = {
        prompt_price_per_million = 0.4,
        cached_prompt_price_per_million = 0.1,
        completion_price_per_million = 1.6
    },
    ["gpt-4.1-nano"] = {
        prompt_price_per_million = 0.1,
        cached_prompt_price_per_million = 0.025,
        completion_price_per_million = 0.4
    },
    ["gpt-5"] = {
        prompt_price_per_million = 1.25,
        cached_prompt_price_per_million = 0.125,
        completion_price_per_million = 10.0
    },
    ["gpt-5-chat-latest"] = {
        prompt_price_per_million = 1.25,
        cached_prompt_price_per_million = 0.125,
        completion_price_per_million = 10.0
    },
    ["gpt-5-mini"] = {
        prompt_price_per_million = 0.25,
        cached_prompt_price_per_million = 0.025,
        completion_price_per_million = 2.0
    },
    ["gpt-5-nano"] = {
        prompt_price_per_million = 0.05,
        cached_prompt_price_per_million = 0.005,
        completion_price_per_million = 0.4
    },
    ["gpt-5.1"] = {
        prompt_price_per_million = 1.25,
        cached_prompt_price_per_million = 0.125,
        completion_price_per_million = 10.0
    },
    ["gpt-5.1-chat-latest"] = {
        prompt_price_per_million = 1.25,
        cached_prompt_price_per_million = 0.125,
        completion_price_per_million = 10.0
    },
    ["gpt-5-codex"] = {
        prompt_price_per_million = 1.25,
        cached_prompt_price_per_million = 0.125,
        completion_price_per_million = 10.0
    },
    ["gpt-5.1-codex"] = {
        prompt_price_per_million = 1.25,
        cached_prompt_price_per_million = 0.125,
        completion_price_per_million = 10.0
    },
    ["gpt-5.1-codex-max"] = {
        prompt_price_per_million = 1.25,
        cached_prompt_price_per_million = 0.125,
        completion_price_per_million = 10.0
    },
    ["gpt-5.2"] = {
        prompt_price_per_million = 1.75,
        cached_prompt_price_per_million = 0.175,
        completion_price_per_million = 14.0
    },
    ["gpt-5.2-chat-latest"] = {
        prompt_price_per_million = 1.75,
        cached_prompt_price_per_million = 0.175,
        completion_price_per_million = 14.0
    },
    ["gpt-5.2-codex"] = {
        prompt_price_per_million = 1.75,
        cached_prompt_price_per_million = 0.175,
        completion_price_per_million = 14.0
    },
    ["gpt-5.3-codex"] = {
        prompt_price_per_million = 1.75,
        cached_prompt_price_per_million = 0.175,
        completion_price_per_million = 14.0
    },
    ["gpt-5.4"] = {
        prompt_price_per_million = 2.5,
        cached_prompt_price_per_million = 0.25,
        prompt_token_threshold = 272000,
        prompt_price_per_million_above_threshold = 5.0,
        cached_prompt_price_per_million_above_threshold = 0.5,
        completion_price_per_million_above_threshold = 22.5,
        completion_price_per_million = 15.0
    },
    ["gpt-5.4-mini"] = {
        prompt_price_per_million = 0.75,
        cached_prompt_price_per_million = 0.075,
        completion_price_per_million = 4.5
    },
    ["gpt-5.4-nano"] = {
        prompt_price_per_million = 0.2,
        cached_prompt_price_per_million = 0.02,
        completion_price_per_million = 1.25
    },
    ["gpt-5.4-pro"] = {
        prompt_price_per_million = 30.0,
        prompt_token_threshold = 272000,
        prompt_price_per_million_above_threshold = 60.0,
        completion_price_per_million_above_threshold = 270.0,
        completion_price_per_million = 180.0
    },
    ["gpt-5-pro"] = {
        prompt_price_per_million = 15.0,
        completion_price_per_million = 120.0
    },
    ["gpt-5.2-pro"] = {
        prompt_price_per_million = 21.0,
        completion_price_per_million = 168.0
    },
    ["gpt-4-turbo"] = {
        prompt_price_per_million = 5.0,
        completion_price_per_million = 15.0
    },
    ["gpt-4"] = {
        prompt_price_per_million = 30.0,
        completion_price_per_million = 60.0
    },
    ["gpt-3.5-turbo"] = {
        prompt_price_per_million = 0.5,
        completion_price_per_million = 1.5
    },
    -- Google Gemini
    ["gemini-3-pro-preview"] = {
        prompt_price_per_million = 2.0,
        cached_prompt_price_per_million = 0.2,
        prompt_token_threshold = 200000,
        prompt_price_per_million_above_threshold = 4.0,
        cached_prompt_price_per_million_above_threshold = 0.4,
        completion_price_per_million_above_threshold = 18.0,
        completion_price_per_million = 12.0,
        cache_storage_price_per_million_tokens_per_hour = 4.5
    },
    ["gemini-3-flash-preview"] = {
        prompt_price_per_million = 0.5,
        cached_prompt_price_per_million = 0.05,
        completion_price_per_million = 3.0,
        cache_storage_price_per_million_tokens_per_hour = 1.0
    },
    ["gemini-2.5-pro"] = {
        prompt_price_per_million = 1.25,
        cached_prompt_price_per_million = 0.125,
        prompt_token_threshold = 200000,
        prompt_price_per_million_above_threshold = 2.5,
        cached_prompt_price_per_million_above_threshold = 0.25,
        completion_price_per_million_above_threshold = 15.0,
        completion_price_per_million = 10.0
    },
    ["gemini-2.5-flash"] = {
        prompt_price_per_million = 0.3,
        cached_prompt_price_per_million = 0.03,
        completion_price_per_million = 2.5
    },
    ["gemini-2.0-flash"] = {
        prompt_price_per_million = 0.1,
        cached_prompt_price_per_million = 0.025,
        completion_price_per_million = 0.4
    },
    ["gemini-1.5-pro"] = {
        prompt_price_per_million = 1.25,
        completion_price_per_million = 5.0
    },
    ["gemini-1.5-flash"] = {
        prompt_price_per_million = 0.075,
        completion_price_per_million = 0.3
    },
    -- DeepSeek
    ["deepseek-chat"] = {
        prompt_price_per_million = 0.14,
        completion_price_per_million = 0.28
    },
    ["deepseek-coder"] = {
        prompt_price_per_million = 0.14,
        completion_price_per_million = 0.28
    },
    -- Qwen
    ["qwen-turbo"] = {
        prompt_price_per_million = 0.04,
        completion_price_per_million = 0.08
    },
    ["qwen-plus"] = {
        prompt_price_per_million = 0.11,
        completion_price_per_million = 0.28
    },
    ["qwen-max"] = {
        prompt_price_per_million = 0.33,
        completion_price_per_million = 1.32
    },
    -- GLM
    ["glm-4"] = {
        prompt_price_per_million = 13.8,
        completion_price_per_million = 13.8
    }
}

local model_price_schema = {
    type = "object",
    properties = {
        prompt_price_per_million = {
            type = "number",
            minimum = 0,
            description = "Price per million prompt tokens (in USD)"
        },
        completion_price_per_million = {
            type = "number",
            minimum = 0,
            description = "Price per million completion tokens (in USD)"
        },
        cached_prompt_price_per_million = {
            type = "number",
            minimum = 0,
            description = "Optional price per million cached prompt tokens (in USD)"
        },
        cache_creation_prompt_price_per_million = {
            type = "number",
            minimum = 0,
            description = "Optional price per million cache-creation prompt tokens (in USD)"
        },
        cache_creation_5m_prompt_price_per_million = {
            type = "number",
            minimum = 0,
            description = "Optional price per million 5-minute cache-creation prompt tokens (in USD)"
        },
        cache_creation_1h_prompt_price_per_million = {
            type = "number",
            minimum = 0,
            description = "Optional price per million 1-hour cache-creation prompt tokens (in USD)"
        },
        cache_creation_5m_prompt_price_per_million_above_threshold = {
            type = "number",
            minimum = 0,
            description = "Optional price per million 5-minute cache-creation prompt tokens above the configured threshold (in USD)"
        },
        cache_creation_1h_prompt_price_per_million_above_threshold = {
            type = "number",
            minimum = 0,
            description = "Optional price per million 1-hour cache-creation prompt tokens above the configured threshold (in USD)"
        },
        cache_storage_price_per_million_tokens_per_hour = {
            type = "number",
            minimum = 0,
            description = "Optional storage price for cached tokens in USD per million tokens per hour"
        },
        prompt_token_threshold = {
            type = "integer",
            minimum = 1,
            description = "Optional prompt token threshold after which alternate tiered pricing applies"
        },
        prompt_price_per_million_above_threshold = {
            type = "number",
            minimum = 0,
            description = "Optional price per million prompt tokens above the configured threshold (in USD)"
        },
        cached_prompt_price_per_million_above_threshold = {
            type = "number",
            minimum = 0,
            description = "Optional price per million cached prompt tokens above the configured threshold (in USD)"
        },
        completion_price_per_million_above_threshold = {
            type = "number",
            minimum = 0,
            description = "Optional price per million completion tokens above the configured threshold (in USD)"
        }
    },
    required = {"prompt_price_per_million", "completion_price_per_million"}
}

local instance_limit_schema = {
    type = "object",
    properties = {
        name = {type = "string"},
        limit = {type = "number", exclusiveMinimum = 0, description = "Limit amount in USD, e.g., 1.00 means $1.00"},
        time_window = {type = "integer", minimum = 1}
    },
    required = {"name", "limit", "time_window"}
}

local model_limit_schema = {
    type = "object",
    properties = {
        limit = {
            type = "number",
            exclusiveMinimum = 0,
            description = "Limit amount in USD for this model"
        },
        time_window = {
            type = "integer",
            minimum = 1,
            description = "Time window in seconds for this model"
        }
    },
    required = {"limit", "time_window"}
}

local schema = {
    type = "object",
    properties = {
        limit = {
            type = "number",
            exclusiveMinimum = 0,
            description = "Limit amount in USD, e.g., 1.00 means $1.00"
        },
        time_window = {type = "integer", exclusiveMinimum = 0},
        show_limit_quota_header = {type = "boolean", default = true},
        limit_strategy = {
            type = "string",
            enum = {"cost", "total_tokens", "prompt_tokens", "completion_tokens"},
            default = "cost",
            description = "The strategy to limit: cost (in USD), or token counts"
        },
        model_prices = {
            type = "object",
            description = "Custom model prices (merge with defaults, all in USD)",
            additionalProperties = model_price_schema
        },
        limit_by_model = {
            type = "boolean",
            default = false,
            description = "When true, rate limit independently per model name"
        },
        model_limits = {
            type = "object",
            description = "Per-model limit overrides (used when limit_by_model is true)",
            additionalProperties = model_limit_schema
        },
        default_cost = {
            type = "number",
            minimum = 0,
            default = 0.01,
            description = "Default cost when token usage unavailable (in USD)"
        },
        default_tokens = {
            type = "integer",
            minimum = 1,
            default = 1000,
            description = "Default tokens when token usage unavailable"
        },
        instances = {
            type = "array",
            items = instance_limit_schema,
            minItems = 1,
        },
        rejected_code = {
            type = "integer", minimum = 200, maximum = 599, default = 503
        },
        rejected_msg = {
            type = "string", minLength = 1
        },
    },
    dependencies = {
        limit = {"time_window"},
        time_window = {"limit"}
    },
    anyOf = {
        {
            required = {"limit", "time_window"}
        },
        {
            required = {"instances"}
        }
    }
}

local _M = {
    version = 0.2,
    priority = 1030,
    name = plugin_name,
    schema = schema
}

local limit_conf_cache = core.lrucache.new({
    ttl = 300, count = 512
})

local model_prices_cache = lrucache.new(1024)

-- USD to internal units multiplier (to avoid floating point issues with resty.limit.count)
local USD_MULTIPLIER = 10000


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local function transform_limit_conf(plugin_conf, instance_conf, instance_name)
    local key = plugin_name .. "#global"
    local limit = plugin_conf.limit
    local time_window = plugin_conf.time_window
    local name = ""
    if instance_conf then
        name = instance_conf.name
        key = instance_conf.name
        limit = instance_conf.limit
        time_window = instance_conf.time_window
    end
    local header_suffix = name ~= "" and ("-" .. name) or ""
    return {
        _vid = key,

        key = key,
        _meta = plugin_conf._meta,
        count = math.ceil(limit * USD_MULTIPLIER),
        time_window = time_window,
        rejected_code = plugin_conf.rejected_code,
        rejected_msg = plugin_conf.rejected_msg,
        show_limit_quota_header = plugin_conf.show_limit_quota_header,
        policy = "local",
        key_type = "constant",
        allow_degradation = false,
        sync_interval = -1,

        -- When ai-rate-limiting has no explicit instances configured, all AI upstream
        -- instances should share the same counter. Keep header names stable in that case,
        -- otherwise limit-count's internal key derivation sees different conf versions.
        limit_header = "X-AI-RateLimit-Limit" .. header_suffix,
        remaining_header = "X-AI-RateLimit-Remaining" .. header_suffix,
        reset_header = "X-AI-RateLimit-Reset" .. header_suffix,
    }
end


local function fetch_limit_conf_kvs(conf)
    local mt = {
        __index = function(t, k)
            if not conf.limit then
                return nil
            end

            local limit_conf = transform_limit_conf(conf, nil, k)
            t[k] = limit_conf
            return limit_conf
        end
    }
    local limit_conf_kvs = setmetatable({}, mt)
    local conf_instances = conf.instances or {}
    for _, limit_conf in ipairs(conf_instances) do
        limit_conf_kvs[limit_conf.name] = transform_limit_conf(conf, limit_conf)
    end
    return limit_conf_kvs
end


local function get_merged_model_prices(conf)
    local conf_prices = conf.model_prices or {}
    local conf_hash = ""
    
    for model, price in pairs(conf_prices) do
        conf_hash = conf_hash .. model .. ":" .. 
                    tostring(price.prompt_price_per_million) .. ":" ..
                    tostring(price.completion_price_per_million) .. ":" ..
                    tostring(price.cached_prompt_price_per_million) .. ":" ..
                    tostring(price.cache_creation_prompt_price_per_million) .. ":" ..
                    tostring(price.cache_creation_5m_prompt_price_per_million) .. ":" ..
                    tostring(price.cache_creation_1h_prompt_price_per_million) .. ":" ..
                    tostring(price.cache_creation_5m_prompt_price_per_million_above_threshold) .. ":" ..
                    tostring(price.cache_creation_1h_prompt_price_per_million_above_threshold) .. ":" ..
                    tostring(price.cache_storage_price_per_million_tokens_per_hour) .. ":" ..
                    tostring(price.prompt_token_threshold) .. ":" ..
                    tostring(price.prompt_price_per_million_above_threshold) .. ":" ..
                    tostring(price.cached_prompt_price_per_million_above_threshold) .. ":" ..
                    tostring(price.completion_price_per_million_above_threshold) .. ";"
    end
    
    local key = "model_prices#" .. conf_hash
    
    local cached = model_prices_cache:get(key)
    if cached then
        return cached
    end

    local merged = {}
    for model, price in pairs(DEFAULT_MODEL_PRICES) do
        merged[model] = {
            prompt_price_per_million = price.prompt_price_per_million,
            completion_price_per_million = price.completion_price_per_million,
            cached_prompt_price_per_million = price.cached_prompt_price_per_million,
            cache_creation_prompt_price_per_million = price.cache_creation_prompt_price_per_million,
            cache_creation_5m_prompt_price_per_million = price.cache_creation_5m_prompt_price_per_million,
            cache_creation_1h_prompt_price_per_million = price.cache_creation_1h_prompt_price_per_million,
            cache_creation_5m_prompt_price_per_million_above_threshold =
                price.cache_creation_5m_prompt_price_per_million_above_threshold,
            cache_creation_1h_prompt_price_per_million_above_threshold =
                price.cache_creation_1h_prompt_price_per_million_above_threshold,
            cache_storage_price_per_million_tokens_per_hour = price.cache_storage_price_per_million_tokens_per_hour,
            prompt_token_threshold = price.prompt_token_threshold,
            prompt_price_per_million_above_threshold = price.prompt_price_per_million_above_threshold,
            cached_prompt_price_per_million_above_threshold =
                price.cached_prompt_price_per_million_above_threshold,
            completion_price_per_million_above_threshold =
                price.completion_price_per_million_above_threshold,
        }
    end

    if conf_prices then
        for model, price in pairs(conf_prices) do
            merged[model] = {
                prompt_price_per_million = price.prompt_price_per_million,
                completion_price_per_million = price.completion_price_per_million,
                cached_prompt_price_per_million = price.cached_prompt_price_per_million,
                cache_creation_prompt_price_per_million = price.cache_creation_prompt_price_per_million,
                cache_creation_5m_prompt_price_per_million = price.cache_creation_5m_prompt_price_per_million,
                cache_creation_1h_prompt_price_per_million = price.cache_creation_1h_prompt_price_per_million,
                cache_creation_5m_prompt_price_per_million_above_threshold =
                    price.cache_creation_5m_prompt_price_per_million_above_threshold,
                cache_creation_1h_prompt_price_per_million_above_threshold =
                    price.cache_creation_1h_prompt_price_per_million_above_threshold,
                cache_storage_price_per_million_tokens_per_hour = price.cache_storage_price_per_million_tokens_per_hour,
                prompt_token_threshold = price.prompt_token_threshold,
                prompt_price_per_million_above_threshold = price.prompt_price_per_million_above_threshold,
                cached_prompt_price_per_million_above_threshold =
                    price.cached_prompt_price_per_million_above_threshold,
                completion_price_per_million_above_threshold =
                    price.completion_price_per_million_above_threshold,
            }
        end
    end

    model_prices_cache:set(key, merged, 300)
    return merged
end


local function normalize_model_name(model)
    if not model then
        return nil
    end

    local normalized = tostring(model):match("^%s*(.-)%s*$")
    if normalized == "" then
        return nil
    end

    normalized = normalized:lower()
    normalized = normalized:match("([^/]+)$") or normalized

    -- Anthropic Claude
    if normalized:find("^claude%-opus%-4%-1%-202%d+$", 1, false)
        or normalized:find("^claude%-opus%-4%-5%-202%d+$", 1, false)
        or normalized:find("^claude%-opus%-4%-202%d+$", 1, false)
        or normalized:find("^claude%-sonnet%-4%-5%-202%d+$", 1, false)
        or normalized:find("^claude%-sonnet%-4%-202%d+$", 1, false)
        or normalized:find("^claude%-haiku%-4%-5%-202%d+$", 1, false) then
        return normalized
    end
    if normalized:find("^claude%-opus%-4%.6", 1, false)
        or normalized:find("^claude%-opus%-4%-6", 1, false)
        or normalized:find("^opus%-4%.6", 1, false)
        or normalized:find("^opus%-4%-6", 1, false) then
        return "claude-opus-4-6"
    end
    if normalized:find("^claude%-opus%-4%.5", 1, false)
        or normalized:find("^claude%-opus%-4%-5", 1, false) then
        return "claude-opus-4-5"
    end
    if normalized:find("^claude%-opus%-4%.1", 1, false)
        or normalized:find("^claude%-opus%-4%-1", 1, false) then
        return "claude-opus-4-1"
    end
    if normalized:find("^claude%-opus%-4%.0", 1, false)
        or normalized:find("^claude%-opus%-4%-0", 1, false) then
        return "claude-opus-4-0"
    end
    if normalized:find("^claude%-opus%-4", 1, false) then
        return "claude-opus-4"
    end
    if normalized:find("^claude%-sonnet%-4%.6", 1, false)
        or normalized:find("^claude%-sonnet%-4%-6", 1, false)
        or normalized:find("^sonnet%-4%.6", 1, false)
        or normalized:find("^sonnet%-4%-6", 1, false) then
        return "claude-sonnet-4-6"
    end
    if normalized:find("^claude%-sonnet%-4%.5", 1, false)
        or normalized:find("^claude%-sonnet%-4%-5", 1, false) then
        return "claude-sonnet-4-5"
    end
    if normalized:find("^claude%-sonnet%-4%.0", 1, false)
        or normalized:find("^claude%-sonnet%-4%-0", 1, false) then
        return "claude-sonnet-4-0"
    end
    if normalized:find("^claude%-sonnet%-4", 1, false) then
        return "claude-sonnet-4"
    end
    if normalized:find("^claude%-haiku%-4%.5", 1, false)
        or normalized:find("^claude%-haiku%-4%-5", 1, false)
        or normalized:find("^haiku%-4%.5", 1, false)
        or normalized:find("^haiku%-4%-5", 1, false) then
        return "claude-haiku-4-5"
    end
    if normalized:find("^claude%-3%-5%-sonnet", 1, false)
        or normalized:find("^claude%-3%.5%-sonnet", 1, false) then
        return "claude-3-5-sonnet"
    end
    if normalized:find("^claude%-3%-sonnet", 1, false) then
        return "claude-3-sonnet"
    end
    if normalized:find("^claude%-3%-opus", 1, false) then
        return "claude-3-opus"
    end
    if normalized:find("^claude%-3%-haiku", 1, false) then
        return "claude-3-haiku"
    end

    -- OpenAI
    if normalized:find("^o4%-mini", 1, false) then
        return "o4-mini"
    end
    if normalized:find("^o3%-mini", 1, false) then
        return "o3-mini"
    end
    if normalized:find("^o3", 1, false) then
        return "o3"
    end
    if normalized:find("^o1%-mini", 1, false) then
        return "o1-mini"
    end
    if normalized:find("^o1", 1, false) then
        return "o1"
    end
    if normalized:find("^gpt5%.4%-pro", 1, false)
        or normalized:find("^gpt%-5%.4%-pro", 1, false) then
        return "gpt-5.4-pro"
    end
    if normalized:find("^gpt5%.4%-mini", 1, false)
        or normalized:find("^gpt%-5%.4%-mini", 1, false) then
        return "gpt-5.4-mini"
    end
    if normalized:find("^gpt5%.4%-nano", 1, false)
        or normalized:find("^gpt%-5%.4%-nano", 1, false) then
        return "gpt-5.4-nano"
    end
    if normalized:find("^gpt5%.4", 1, false)
        or normalized:find("^gpt%-5%.4", 1, false) then
        return "gpt-5.4"
    end
    if normalized:find("^gpt5%.3%-codex", 1, false)
        or normalized:find("^gpt%-5%.3%-codex", 1, false) then
        return "gpt-5.3-codex"
    end
    if normalized:find("^gpt%-5%.2%-codex", 1, false)
        or normalized:find("^gpt5%.2%-codex", 1, false) then
        return "gpt-5.2-codex"
    end
    if normalized:find("^gpt%-5%.2%-chat%-latest", 1, false) then
        return "gpt-5.2-chat-latest"
    end
    if normalized:find("^gpt%-5%.2%-pro", 1, false) then
        return "gpt-5.2-pro"
    end
    if normalized:find("^gpt%-5%.2%-mini", 1, false) then
        return "gpt-5-mini"
    end
    if normalized:find("^gpt%-5%.2%-nano", 1, false) then
        return "gpt-5-nano"
    end
    if normalized:find("^gpt%-5%.2", 1, false) then
        return "gpt-5.2"
    end
    if normalized:find("^gpt%-5%.1%-codex%-max", 1, false) then
        return "gpt-5.1-codex-max"
    end
    if normalized:find("^gpt%-5%.1%-codex", 1, false) then
        return "gpt-5.1-codex"
    end
    if normalized:find("^gpt%-5%-codex", 1, false) then
        return "gpt-5-codex"
    end
    if normalized:find("^gpt%-5%.1%-chat%-latest", 1, false) then
        return "gpt-5.1-chat-latest"
    end
    if normalized:find("^gpt%-5%-chat%-latest", 1, false) then
        return "gpt-5-chat-latest"
    end
    if normalized:find("^gpt%-5%-mini", 1, false) then
        return "gpt-5-mini"
    end
    if normalized:find("^gpt%-5%-nano", 1, false) then
        return "gpt-5-nano"
    end
    if normalized:find("^gpt%-5%-pro", 1, false) then
        return "gpt-5-pro"
    end
    if normalized:find("^gpt%-5%.1", 1, false) then
        return "gpt-5.1"
    end
    if normalized:find("^gpt%-5", 1, false) then
        return "gpt-5"
    end
    if normalized:find("^gpt%-4%.1%-mini", 1, false) then
        return "gpt-4.1-mini"
    end
    if normalized:find("^gpt%-4%.1%-nano", 1, false) then
        return "gpt-4.1-nano"
    end
    if normalized:find("^gpt%-4%.1", 1, false) then
        return "gpt-4.1"
    end
    if normalized:find("^gpt%-4%-turbo", 1, false) then
        return "gpt-4-turbo"
    end
    if normalized:find("^gpt%-4o%-mini", 1, false) then
        return "gpt-4o-mini"
    end
    if normalized:find("^gpt%-4o", 1, false) then
        return "gpt-4o"
    end
    if normalized:find("^gpt%-4%-%d+", 1, false) then
        return "gpt-4"
    end
    if normalized:find("^gpt%-3%.5%-turbo", 1, false) then
        return "gpt-3.5-turbo"
    end

    -- Google Gemini
    if normalized:find("^gemini%-3%-1%-pro", 1, false)
        or normalized:find("^gemini%-3%.1%-pro", 1, false) then
        return "gemini-3.1-pro-preview"
    end
    if normalized:find("^gemini%-3%-pro", 1, false) then
        return "gemini-3-pro-preview"
    end
    if normalized:find("^gemini%-3%-flash", 1, false) then
        return "gemini-3-flash-preview"
    end
    if normalized:find("^gemini%-2%.5%-pro", 1, false) then
        return "gemini-2.5-pro"
    end
    if normalized:find("^gemini%-2%.5%-flash", 1, false) then
        return "gemini-2.5-flash"
    end
    if normalized:find("^gemini%-2%.0%-flash", 1, false) then
        return "gemini-2.0-flash"
    end
    if normalized:find("^gemini%-1%.5%-pro", 1, false) then
        return "gemini-1.5-pro"
    end
    if normalized:find("^gemini%-1%.5%-flash", 1, false) then
        return "gemini-1.5-flash"
    end

    -- DeepSeek
    if normalized:find("^deepseek%-coder", 1, false) then
        return "deepseek-coder"
    end
    if normalized:find("^deepseek%-chat", 1, false) then
        return "deepseek-chat"
    end

    -- Qwen
    if normalized:find("^qwen%-turbo", 1, false) then
        return "qwen-turbo"
    end
    if normalized:find("^qwen%-plus", 1, false) then
        return "qwen-plus"
    end
    if normalized:find("^qwen%-max", 1, false) then
        return "qwen-max"
    end

    return normalized
end


local function get_request_model(ctx)
    local model = ctx.var.llm_model
    if model and tostring(model):match("%S") then
        return normalize_model_name(model)
    end

    local body = core.request.get_body()
    if body then
        local data = core.json.decode(body)
        if data and data.model and tostring(data.model):match("%S") then
            return normalize_model_name(data.model)
        end
    end
    return nil
end


local function apply_model_to_limit_conf(limit_conf, model, conf)
    if not model then
        return limit_conf
    end

    local model_limit = conf.model_limits and conf.model_limits[model]

    return {
        _vid = limit_conf._vid .. "#" .. model,
        key = limit_conf.key .. "#" .. model,
        _meta = limit_conf._meta,
        count = model_limit and math.ceil(model_limit.limit * USD_MULTIPLIER) or limit_conf.count,
        time_window = model_limit and model_limit.time_window or limit_conf.time_window,
        rejected_code = limit_conf.rejected_code,
        rejected_msg = limit_conf.rejected_msg,
        show_limit_quota_header = limit_conf.show_limit_quota_header,
        policy = limit_conf.policy,
        key_type = limit_conf.key_type,
        allow_degradation = limit_conf.allow_degradation,
        sync_interval = limit_conf.sync_interval,
        limit_header = limit_conf.limit_header,
        remaining_header = limit_conf.remaining_header,
        reset_header = limit_conf.reset_header,
    }
end

local function get_usage_breakdown(ctx)
    local usage = ctx.ai_token_usage
    if not usage then
        return nil
    end

    local prompt_tokens = usage.prompt_tokens or 0
    local completion_tokens = usage.completion_tokens or 0
    if prompt_tokens == 0 and completion_tokens == 0 then
        return nil
    end

    local cached_prompt_tokens = usage.cached_prompt_tokens or usage.cache_read_prompt_tokens or 0
    local cache_creation_prompt_tokens = usage.cache_creation_prompt_tokens or 0
    local cache_creation_5m_prompt_tokens = usage.cache_creation_5m_prompt_tokens or 0
    local cache_creation_1h_prompt_tokens = usage.cache_creation_1h_prompt_tokens or 0
    local cache_storage_token_hours = usage.cache_storage_token_hours
    if cache_storage_token_hours == nil and usage.cache_storage_tokens and
       usage.cache_storage_hours then
        cache_storage_token_hours = usage.cache_storage_tokens * usage.cache_storage_hours
    end
    cache_storage_token_hours = cache_storage_token_hours or 0

    if (cache_creation_5m_prompt_tokens > 0 or cache_creation_1h_prompt_tokens > 0) and
       cache_creation_prompt_tokens == 0 then
        cache_creation_prompt_tokens = cache_creation_5m_prompt_tokens + cache_creation_1h_prompt_tokens
    end

    local uncached_prompt_tokens = usage.uncached_prompt_tokens
    if uncached_prompt_tokens == nil then
        uncached_prompt_tokens = math.max(
            prompt_tokens - cached_prompt_tokens - cache_creation_prompt_tokens, 0)
    end

    return {
        prompt_tokens = prompt_tokens,
        completion_tokens = completion_tokens,
        cached_prompt_tokens = cached_prompt_tokens,
        cache_creation_prompt_tokens = cache_creation_prompt_tokens,
        cache_creation_5m_prompt_tokens = cache_creation_5m_prompt_tokens,
        cache_creation_1h_prompt_tokens = cache_creation_1h_prompt_tokens,
        cache_storage_token_hours = cache_storage_token_hours,
        uncached_prompt_tokens = uncached_prompt_tokens,
    }
end


local function calculate_cost_usd(conf, ctx)
    local model = ctx.var.llm_model
    if not model or not tostring(model):match("%S") then
        return nil
    end

    local usage_info = get_usage_breakdown(ctx)
    if not usage_info then
        return nil
    end

    local prompt_tokens = usage_info.prompt_tokens
    local completion_tokens = usage_info.completion_tokens
    local cached_prompt_tokens = usage_info.cached_prompt_tokens
    local cache_creation_prompt_tokens = usage_info.cache_creation_prompt_tokens
    local cache_creation_5m_prompt_tokens = usage_info.cache_creation_5m_prompt_tokens
    local cache_creation_1h_prompt_tokens = usage_info.cache_creation_1h_prompt_tokens
    local cache_storage_token_hours = usage_info.cache_storage_token_hours
    local uncached_prompt_tokens = usage_info.uncached_prompt_tokens

    local model_prices = get_merged_model_prices(conf)
    local normalized_model = normalize_model_name(model)
    local price_info = model_prices[normalized_model] or model_prices[model]

    if not price_info then
        core.log.warn("unknown model price for: ", model, " (normalized: ", normalized_model or "nil", "), using default price")
        price_info = {
            prompt_price_per_million = 1.0,
            completion_price_per_million = 3.0,
            cached_prompt_price_per_million = 1.0,
            cache_creation_prompt_price_per_million = 1.0,
            cache_creation_5m_prompt_price_per_million = 1.0,
            cache_creation_1h_prompt_price_per_million = 1.0,
        }
    end

    local is_claude_model = normalized_model and normalized_model:find("^claude%-", 1, false)
    local prompt_price_per_million = price_info.prompt_price_per_million
    local completion_price_per_million = price_info.completion_price_per_million
    local cached_prompt_price_per_million = price_info.cached_prompt_price_per_million
        or (is_claude_model and (price_info.prompt_price_per_million * 0.1))
        or price_info.prompt_price_per_million
    local cache_creation_5m_prompt_price_per_million =
        price_info.cache_creation_5m_prompt_price_per_million
        or price_info.cache_creation_prompt_price_per_million
        or (is_claude_model and (price_info.prompt_price_per_million * 1.25))
        or price_info.prompt_price_per_million
    local cache_creation_1h_prompt_price_per_million =
        price_info.cache_creation_1h_prompt_price_per_million
        or price_info.cache_creation_prompt_price_per_million
        or (is_claude_model and (price_info.prompt_price_per_million * 2.0))
        or price_info.prompt_price_per_million

    if price_info.prompt_token_threshold and prompt_tokens > price_info.prompt_token_threshold then
        prompt_price_per_million = price_info.prompt_price_per_million_above_threshold
            or prompt_price_per_million
        cached_prompt_price_per_million =
            price_info.cached_prompt_price_per_million_above_threshold
            or cached_prompt_price_per_million
        cache_creation_5m_prompt_price_per_million =
            price_info.cache_creation_5m_prompt_price_per_million_above_threshold
            or cache_creation_5m_prompt_price_per_million
        cache_creation_1h_prompt_price_per_million =
            price_info.cache_creation_1h_prompt_price_per_million_above_threshold
            or cache_creation_1h_prompt_price_per_million
        completion_price_per_million = price_info.completion_price_per_million_above_threshold
            or completion_price_per_million
    end

    local prompt_cost = (uncached_prompt_tokens / 1000000) * prompt_price_per_million
    local cached_prompt_cost = (cached_prompt_tokens / 1000000) *
        cached_prompt_price_per_million
    local cache_creation_prompt_cost
    if cache_creation_5m_prompt_tokens > 0 or cache_creation_1h_prompt_tokens > 0 then
        cache_creation_prompt_cost =
            (cache_creation_5m_prompt_tokens / 1000000) * cache_creation_5m_prompt_price_per_million
            + (cache_creation_1h_prompt_tokens / 1000000) * cache_creation_1h_prompt_price_per_million
    else
        cache_creation_prompt_cost = (cache_creation_prompt_tokens / 1000000) *
            cache_creation_5m_prompt_price_per_million
    end
    local completion_cost = (completion_tokens / 1000000) * completion_price_per_million
    local cache_storage_cost = (cache_storage_token_hours / 1000000) *
        (price_info.cache_storage_price_per_million_tokens_per_hour or 0)
    local total_cost_usd = prompt_cost + cached_prompt_cost + cache_creation_prompt_cost
        + cache_storage_cost + completion_cost

    local cost_units = math.ceil(total_cost_usd * USD_MULTIPLIER)

    core.log.info("model: ", model, ", uncached_prompt_tokens: ", uncached_prompt_tokens,
                  ", cached_prompt_tokens: ", cached_prompt_tokens,
                  ", cache_creation_prompt_tokens: ", cache_creation_prompt_tokens,
                  ", cache_creation_5m_prompt_tokens: ", cache_creation_5m_prompt_tokens,
                  ", cache_creation_1h_prompt_tokens: ", cache_creation_1h_prompt_tokens,
                  ", cache_storage_token_hours: ", cache_storage_token_hours,
                  ", completion_tokens: ", completion_tokens,
                  ", cost_usd: ", total_cost_usd, ", cost_units: ", cost_units)

    return cost_units, total_cost_usd, usage_info
end


local function get_token_usage(conf, ctx)
    local usage = ctx.ai_token_usage
    if not usage then
        return
    end
    return usage[conf.limit_strategy]
end


local function get_usage_value(conf, ctx)
    local strategy = conf.limit_strategy or "cost"

    if strategy == "cost" then
        return calculate_cost_usd(conf, ctx)
    else
        return get_token_usage(conf, ctx)
    end
end


function _M.access(conf, ctx)
    local ai_instance_name = ctx.picked_ai_instance_name
    if not ai_instance_name then
        return
    end

    local limit_conf_kvs = limit_conf_cache(conf, nil, fetch_limit_conf_kvs, conf)
    local limit_conf = limit_conf_kvs[ai_instance_name]
    if not limit_conf then
        return
    end

    if conf.limit_by_model then
        local model = get_request_model(ctx)
        if model then
            limit_conf = apply_model_to_limit_conf(limit_conf, model, conf)
        end
    end

    local code, msg = limit_count.rate_limit(limit_conf, ctx, plugin_name, 1, true)
    if code then
        ctx.ai_rate_limiting = true
        return code, msg
    end
end


function _M.check_instance_status(conf, ctx, instance_name)
    if conf == nil then
        local plugins = ctx.plugins
        for i = 1, #plugins, 2 do
            if plugins[i]["name"] == plugin_name then
                conf = plugins[i + 1]
            end
        end
    end
    if not conf then
        return true
    end

    instance_name = instance_name or ctx.picked_ai_instance_name
    if not instance_name then
        return nil, "missing instance_name"
    end

    if type(instance_name) ~= "string" then
        return nil, "invalid instance_name"
    end

    local limit_conf_kvs = limit_conf_cache(conf, nil, fetch_limit_conf_kvs, conf)
    local limit_conf = limit_conf_kvs[instance_name]
    if not limit_conf then
        return true
    end

    if conf.limit_by_model then
        local model = get_request_model(ctx)
        if model then
            limit_conf = apply_model_to_limit_conf(limit_conf, model, conf)
        end
    end

    local code, _ = limit_count.rate_limit(limit_conf, ctx, plugin_name, 1, true)
    if code then
        core.log.info("rate limit for instance: ", instance_name, " code: ", code)
        return false
    end
    return true
end


function _M.log(conf, ctx)
    local instance_name = ctx.picked_ai_instance_name
    if not instance_name then
        return
    end

    if ctx.ai_rate_limiting then
        return
    end

    local used_value = get_usage_value(conf, ctx)

    if not used_value or used_value <= 0 then
        core.log.warn("failed to get usage value for llm service, used_value: ",
                      used_value or "nil", ", using default cost")
        local strategy = conf.limit_strategy or "cost"
        if strategy == "cost" then
            used_value = math.ceil((conf.default_cost or 0.01) * USD_MULTIPLIER)
        else
            used_value = conf.default_tokens or 1000
        end
    end

    local model = conf.limit_by_model and normalize_model_name(ctx.var.llm_model) or nil

    core.log.info("instance name: ", instance_name,
                  ", limit_strategy: ", conf.limit_strategy or "cost",
                  ", used_value: ", used_value,
                  ", model: ", model or "all")

    local limit_conf_kvs = limit_conf_cache(conf, nil, fetch_limit_conf_kvs, conf)
    local limit_conf = limit_conf_kvs[instance_name]
    if limit_conf then
        if model then
            limit_conf = apply_model_to_limit_conf(limit_conf, model, conf)
        end

        local committed_value = used_value
        if committed_value > limit_conf.count then
            core.log.warn("usage value exceeds configured limit count, saturating counter ",
                          "for future requests, instance name: ", instance_name,
                          ", model: ", model or "all",
                          ", used_value: ", used_value,
                          ", limit_count: ", limit_conf.count)
            committed_value = limit_conf.count
        end

        local code, err = limit_count.rate_limit(limit_conf, ctx, plugin_name, committed_value)
        if code then
            core.log.warn("failed to commit ai usage to rate limiter, instance name: ",
                          instance_name,
                          ", model: ", model or "all",
                          ", used_value: ", used_value,
                          ", committed_value: ", committed_value,
                          ", code: ", code,
                          ", err: ", core.json.delay_encode(err, true))
        end
    end
end

_M.normalize_model_name = normalize_model_name
_M.get_usage_breakdown = get_usage_breakdown
_M.calculate_cost_usd = calculate_cost_usd


return _M
