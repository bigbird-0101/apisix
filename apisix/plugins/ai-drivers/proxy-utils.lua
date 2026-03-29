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
local os = os

local _M = {}


--- Build proxy options for resty.http
--- Priority: environment variables > config.yaml (plugin_attr.ai-proxy)
function _M.build_proxy_opts()
    -- 1. Try environment variables first
    local http_proxy = os.getenv("HTTP_PROXY") or os.getenv("http_proxy")
    local https_proxy = os.getenv("HTTPS_PROXY") or os.getenv("https_proxy")
    local no_proxy = os.getenv("NO_PROXY") or os.getenv("no_proxy")

    -- 2. Fallback to config.yaml: plugin_attr.ai-proxy.proxy
    if not http_proxy and not https_proxy then
        local local_conf = core.config.local_conf()
        local proxy_conf = core.table.try_read_attr(
            local_conf, "plugin_attr", "ai-proxy", "proxy")

        if proxy_conf then
            http_proxy = proxy_conf.http_proxy
            https_proxy = proxy_conf.https_proxy
            no_proxy = no_proxy or proxy_conf.no_proxy
        end
    end

    core.log.info("proxy config: http_proxy=", http_proxy or "nil",
                  ", https_proxy=", https_proxy or "nil",
                  ", no_proxy=", no_proxy or "nil")

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


return _M
