"""
AI rate limit quota exporter for Prometheus.

Reads real rate-limit counter values from APISIX response headers
(X-AI-RateLimit-Limit/Remaining) for each consumer, exposes as
Prometheus metrics.

Works for any limit_strategy (cost / tokens) since it mirrors whatever
the plugin returns.

Metrics exposed on :8000/metrics
  - apisix_ai_rate_limit_limit{consumer,instance}      # configured limit (internal units)
  - apisix_ai_rate_limit_remaining{consumer,instance}  # current remaining
  - apisix_ai_rate_limit_used{consumer,instance}       # limit - remaining
  - apisix_ai_rate_limit_used_usd{consumer,instance}   # used / 10000 (USD)
  - apisix_ai_rate_limit_used_pct{consumer,instance}   # used / limit * 100

Env vars:
  APISIX_ADMIN_URL   default http://127.0.0.1:9180
  APISIX_ADMIN_KEY   required
  PROBE_ROUTE_URL    default http://127.0.0.1:9080/openclaw/codex/responses
  SCRAPE_INTERVAL    default 30 (seconds)
"""
import os
import time
import threading
import requests
from prometheus_client import start_http_server, Gauge, REGISTRY
from prometheus_client.core import CollectorRegistry

ADMIN_URL = os.environ.get("APISIX_ADMIN_URL", "http://127.0.0.1:9180")
ADMIN_KEY = os.environ.get("APISIX_ADMIN_KEY", os.environ.get("admin_key", ""))
PROBE_URL = os.environ.get("PROBE_ROUTE_URL", "http://127.0.0.1:9080/openclaw/codex/responses")
INTERVAL = int(os.environ.get("SCRAPE_INTERVAL", "30"))
USD_MULT = 10000

# Metrics
limit_g = Gauge(
    "apisix_ai_rate_limit_limit",
    "Configured rate limit (internal units, 1 USD = 10000)",
    ["consumer", "instance_name"],
)
remaining_g = Gauge(
    "apisix_ai_rate_limit_remaining",
    "Current remaining quota (internal units)",
    ["consumer", "instance_name"],
)
used_g = Gauge(
    "apisix_ai_rate_limit_used",
    "Used quota (limit - remaining, internal units)",
    ["consumer", "instance_name"],
)
used_usd_g = Gauge(
    "apisix_ai_rate_limit_used_usd",
    "Used quota in USD",
    ["consumer", "instance_name"],
)
used_pct_g = Gauge(
    "apisix_ai_rate_limit_used_pct",
    "Used quota as percent of limit",
    ["consumer", "instance_name"],
)


def get_consumers():
    try:
        resp = requests.get(
            f"{ADMIN_URL}/apisix/admin/consumers",
            headers={"X-API-KEY": ADMIN_KEY},
            timeout=5,
        )
        if resp.status_code != 200:
            return []
        data = resp.json()
        out = []
        for node in data.get("list", data.get("node", {}).get("nodes", [])):
            v = node.get("value", node)
            username = v.get("username", "")
            plugins = v.get("plugins", {})
            key_auth = plugins.get("key-auth", {})
            api_key = key_auth.get("key", "")
            rate_limit = plugins.get("ai-rate-limiting")
            if username and api_key and rate_limit:
                out.append({"username": username, "api_key": api_key})
        return out
    except Exception as e:
        print(f"[ERR] get_consumers: {e}")
        return []


def probe_quota(api_key):
    """Send a dummy probe to trigger rate-limit headers without incurring much cost."""
    try:
        resp = requests.post(
            PROBE_URL,
            headers={"Authorization": api_key, "Content-Type": "application/json"},
            json={"model": "nop", "input": "x", "max_output_tokens": 1},
            timeout=5,
        )
        info = {}
        for k, v in resp.headers.items():
            if "RateLimit" in k:
                # e.g. X-AI-RateLimit-Limit-ai-proxy-openai-codex
                parts = k.replace("X-AI-RateLimit-", "").split("-", 1)
                kind = parts[0].lower()  # limit / remaining / reset
                instance = parts[1] if len(parts) > 1 else ""
                info.setdefault(instance, {})[kind] = v
        return info
    except Exception as e:
        print(f"[ERR] probe: {e}")
        return {}


def update_metrics():
    consumers = get_consumers()
    print(f"[INFO] scraping {len(consumers)} consumers")
    for c in consumers:
        username = c["username"]
        info = probe_quota(c["api_key"])
        if not info:
            continue
        for instance, vals in info.items():
            try:
                limit = int(vals.get("limit", 0))
                remaining = int(vals.get("remaining", 0))
                used = limit - remaining
                pct = (used / limit * 100) if limit > 0 else 0
                limit_g.labels(username, instance).set(limit)
                remaining_g.labels(username, instance).set(remaining)
                used_g.labels(username, instance).set(used)
                used_usd_g.labels(username, instance).set(used / USD_MULT)
                used_pct_g.labels(username, instance).set(pct)
            except Exception as e:
                print(f"[ERR] metrics for {username}/{instance}: {e}")


def loop():
    while True:
        update_metrics()
        time.sleep(INTERVAL)


if __name__ == "__main__":
    if not ADMIN_KEY:
        print("ERROR: APISIX_ADMIN_KEY env var not set")
        exit(1)
    print(f"Admin URL: {ADMIN_URL}")
    print(f"Probe URL: {PROBE_URL}")
    print(f"Scrape interval: {INTERVAL}s")
    print("Exporter listening on :8000/metrics")

    threading.Thread(target=loop, daemon=True).start()
    start_http_server(8000)
    # Block forever
    while True:
        time.sleep(3600)
