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
    ["gpt-4"] = {
        prompt_price_per_million = 30.0,
        completion_price_per_million = 60.0
    },
    ["gpt-4-turbo"] = {
        prompt_price_per_million = 10.0,
        completion_price_per_million = 30.0
    },
    ["gpt-4o"] = {
        prompt_price_per_million = 2.5,
        completion_price_per_million = 10.0
    },
    ["gpt-4o-mini"] = {
        prompt_price_per_million = 0.15,
        completion_price_per_million = 0.6
    },
    ["gpt-3.5-turbo"] = {
        prompt_price_per_million = 0.5,
        completion_price_per_million = 1.5
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
    ["claude-3-5-sonnet"] = {
        prompt_price_per_million = 3.0,
        completion_price_per_million = 15.0
    },
    ["claude-sonnet-4"] = {
        prompt_price_per_million = 3.0,
        completion_price_per_million = 15.0
    },
    ["claude-sonnet-4-6"] = {
        prompt_price_per_million = 3.0,
        completion_price_per_million = 15.0
    },
    ["deepseek-chat"] = {
        prompt_price_per_million = 0.14,
        completion_price_per_million = 0.28
    },
    ["deepseek-coder"] = {
        prompt_price_per_million = 0.14,
        completion_price_per_million = 0.28
    },
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
    ["glm-4"] = {
        prompt_price_per_million = 13.8,
        completion_price_per_million = 13.8
    },
    ["gemini-pro"] = {
        prompt_price_per_million = 0.5,
        completion_price_per_million = 1.5
    },
    ["gemini-1.5-pro"] = {
        prompt_price_per_million = 3.5,
        completion_price_per_million = 10.5
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


local function get_request_model(ctx)
    local model = ctx.var.llm_model
    if model then
        return normalize_model_name(model)
    end

    local body = core.request.get_body()
    if body then
        local data = core.json.decode(body)
        if data and data.model then
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
        count = model_limit and model_limit.limit or limit_conf.count,
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


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local function transform_limit_conf(plugin_conf, instance_conf, instance_name)
    local key = plugin_name .. "#global"
    local limit = plugin_conf.limit
    local time_window = plugin_conf.time_window
    local name = instance_name or ""
    if instance_conf then
        name = instance_conf.name
        key = instance_conf.name
        limit = instance_conf.limit
        time_window = instance_conf.time_window
    end
    return {
        _vid = key,

        key = key,
        _meta = plugin_conf._meta,
        count = limit,
        time_window = time_window,
        rejected_code = plugin_conf.rejected_code,
        rejected_msg = plugin_conf.rejected_msg,
        show_limit_quota_header = plugin_conf.show_limit_quota_header,
        policy = "local",
        key_type = "constant",
        allow_degradation = false,
        sync_interval = -1,

        limit_header = "X-AI-RateLimit-Limit-" .. name,
        remaining_header = "X-AI-RateLimit-Remaining-" .. name,
        reset_header = "X-AI-RateLimit-Reset-" .. name,
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
                    tostring(price.completion_price_per_million) .. ";"
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
            completion_price_per_million = price.completion_price_per_million
        }
    end

    if conf_prices then
        for model, price in pairs(conf_prices) do
            merged[model] = {
                prompt_price_per_million = price.prompt_price_per_million,
                completion_price_per_million = price.completion_price_per_million
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

    local normalized = model:lower()

    normalized = normalized:gsub("^claude%-3%-5%-sonnet%-", "claude-3-5-sonnet-")
    normalized = normalized:gsub("^claude%-3%.5%-sonnet%-", "claude-3-5-sonnet-")
    normalized = normalized:gsub("^claude%-sonnet%-4%-6.*$", "claude-sonnet-4-6")
    normalized = normalized:gsub("^claude%-sonnet%-4.*$", "claude-sonnet-4")
    normalized = normalized:gsub("^claude%-3%-5%-sonnet.*$", "claude-3-5-sonnet")
    normalized = normalized:gsub("^claude%-3%-sonnet.*$", "claude-3-sonnet")
    normalized = normalized:gsub("^claude%-3%-opus.*$", "claude-3-opus")
    normalized = normalized:gsub("^claude%-3%-haiku.*$", "claude-3-haiku")
    normalized = normalized:gsub("^gpt%-4%-turbo.*$", "gpt-4-turbo")
    normalized = normalized:gsub("^gpt%-4o%-mini.*$", "gpt-4o-mini")
    normalized = normalized:gsub("^gpt%-4o.*$", "gpt-4o")
    normalized = normalized:gsub("^gpt%-4%-%d+.*$", "gpt-4")
    normalized = normalized:gsub("^gpt%-3%.5%-turbo.*$", "gpt-3.5-turbo")
    normalized = normalized:gsub("^deepseek%-coder.*$", "deepseek-coder")
    normalized = normalized:gsub("^deepseek%-chat.*$", "deepseek-chat")
    normalized = normalized:gsub("^qwen%-turbo.*$", "qwen-turbo")
    normalized = normalized:gsub("^qwen%-plus.*$", "qwen-plus")
    normalized = normalized:gsub("^qwen%-max.*$", "qwen-max")
    normalized = normalized:gsub("^gemini%-1%.5%-pro.*$", "gemini-1.5-pro")
    normalized = normalized:gsub("^gemini%-pro.*$", "gemini-pro")

    return normalized
end


local function calculate_cost_usd(conf, ctx)
    local usage = ctx.ai_token_usage
    if not usage then
        return nil
    end

    local model = ctx.var.llm_model
    if not model then
        return nil
    end

    local prompt_tokens = usage.prompt_tokens or 0
    local completion_tokens = usage.completion_tokens or 0

    if prompt_tokens == 0 and completion_tokens == 0 then
        return nil
    end

    local model_prices = get_merged_model_prices(conf)
    local normalized_model = normalize_model_name(model)
    local price_info = model_prices[normalized_model] or model_prices[model]

    if not price_info then
        core.log.warn("unknown model price for: ", model, " (normalized: ", normalized_model or "nil", "), using default price")
        price_info = {
            prompt_price_per_million = 1.0,
            completion_price_per_million = 3.0
        }
    end

    local prompt_cost = (prompt_tokens / 1000000) * price_info.prompt_price_per_million
    local completion_cost = (completion_tokens / 1000000) * price_info.completion_price_per_million
    local total_cost_usd = prompt_cost + completion_cost

    core.log.info("model: ", model, ", prompt_tokens: ", prompt_tokens,
                  ", completion_tokens: ", completion_tokens,
                  ", cost_usd: ", total_cost_usd)

    return total_cost_usd
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
            used_value = conf.default_cost or 0.01
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
        limit_count.rate_limit(limit_conf, ctx, plugin_name, used_value)
    end
end


return _M
