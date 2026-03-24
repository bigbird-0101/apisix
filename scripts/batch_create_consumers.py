#!/usr/bin/env python3
"""
Batch create APISIX consumers with key-auth and ai-rate-limiting plugins.

Usage:
    python batch_create_consumers.py

Configure APISIX_ADMIN_URL, APISIX_ADMIN_KEY, and CONSUMERS list below.
"""

import requests
import json
import sys

# ============ Configuration ============

APISIX_ADMIN_URL = "http://127.0.0.1:9180"  # APISIX Admin API address
APISIX_ADMIN_KEY = "your-admin-api-key"      # Admin API Key

# Default ai-rate-limiting config (shared by all consumers)
DEFAULT_RATE_LIMIT_CONFIG = {
    "rejected_code": 429,
    "limit": 27.5,            # Daily limit in USD ($27.5 ≈ ¥200)
    "limit_strategy": "cost",
    "limit_by_model": True,
    "rejected_msg": "您的每日 200 元配额已用完",
    "time_window": 86400,     # 1 day
    "model_limits": {
        # Per-model limits (USD), leave empty to use global limit for all models
        # "claude-opus-4": {"limit": 10, "time_window": 86400},
        # "claude-sonnet-4-6": {"limit": 20, "time_window": 86400},
        # "claude-haiku-4-5": {"limit": 15, "time_window": 86400},
        # "gpt-4o": {"limit": 20, "time_window": 86400},
        # "gemini-2.5-pro": {"limit": 15, "time_window": 86400},
    },
    "model_prices": {
        # Anthropic Claude
        "claude-opus-4": {
            "prompt_price_per_million": 15.0,
            "completion_price_per_million": 75.0
        },
        "claude-sonnet-4-6": {
            "prompt_price_per_million": 3.0,
            "completion_price_per_million": 15.0
        },
        "claude-sonnet-4": {
            "prompt_price_per_million": 3.0,
            "completion_price_per_million": 15.0
        },
        "claude-haiku-4-5": {
            "prompt_price_per_million": 1.0,
            "completion_price_per_million": 5.0
        },
        # OpenAI
        "o3": {
            "prompt_price_per_million": 2.0,
            "completion_price_per_million": 8.0
        },
        "o3-mini": {
            "prompt_price_per_million": 1.1,
            "completion_price_per_million": 4.4
        },
        "o4-mini": {
            "prompt_price_per_million": 1.1,
            "completion_price_per_million": 4.4
        },
        "gpt-4o": {
            "prompt_price_per_million": 2.5,
            "completion_price_per_million": 10.0
        },
        "gpt-4o-mini": {
            "prompt_price_per_million": 0.15,
            "completion_price_per_million": 0.6
        },
        # Google Gemini
        "gemini-2.5-pro": {
            "prompt_price_per_million": 1.25,
            "completion_price_per_million": 10.0
        },
        "gemini-2.5-flash": {
            "prompt_price_per_million": 0.3,
            "completion_price_per_million": 2.5
        },
        "gemini-2.0-flash": {
            "prompt_price_per_million": 0.1,
            "completion_price_per_million": 0.4
        },
    }
}

# Consumer list: each item is (username, api_key)
# api_key format follows your existing pattern: "Bearer sk-ant-oat-{username}"
CONSUMERS = [
    # Add your consumers here, e.g.:
    # ("qiyu_wecom_145_246_214_man", "Bearer sk-ant-oat-qiyu_wecom_145_246_214_man"),
    # ("user_alice", "Bearer sk-ant-oat-user_alice"),
    # ("user_bob", "Bearer sk-ant-oat-user_bob"),
]

# Or generate consumers from a username list (auto-generate api_key)
USERNAMES = [
    # "qiyu_wecom_145_246_214_man",
    # "user_alice",
    # "user_bob",
]

# ============ End Configuration ============


def build_consumer(username, api_key, rate_limit_config=None):
    """Build consumer payload for APISIX Admin API."""
    config = rate_limit_config or DEFAULT_RATE_LIMIT_CONFIG
    return {
        "username": username,
        "plugins": {
            "key-auth": {
                "key": api_key
            },
            "ai-rate-limiting": config
        }
    }


def create_consumer(username, api_key, rate_limit_config=None):
    """Create or update a consumer via APISIX Admin API."""
    url = f"{APISIX_ADMIN_URL}/apisix/admin/consumers"
    headers = {
        "X-API-KEY": APISIX_ADMIN_KEY,
        "Content-Type": "application/json"
    }
    payload = build_consumer(username, api_key, rate_limit_config)

    try:
        resp = requests.put(url, headers=headers, json=payload, timeout=10)
        if resp.status_code in (200, 201):
            print(f"[OK]   {username}")
            return True
        else:
            print(f"[FAIL] {username} - HTTP {resp.status_code}: {resp.text}")
            return False
    except requests.RequestException as e:
        print(f"[ERR]  {username} - {e}")
        return False


def main():
    consumers = list(CONSUMERS)

    # Auto-generate from USERNAMES list
    for name in USERNAMES:
        api_key = f"Bearer sk-ant-oat-{name}"
        consumers.append((name, api_key))

    if not consumers:
        print("No consumers configured. Edit CONSUMERS or USERNAMES in the script.")
        sys.exit(1)

    print(f"Creating {len(consumers)} consumers on {APISIX_ADMIN_URL} ...")
    print("-" * 60)

    success = 0
    failed = 0
    for username, api_key in consumers:
        if create_consumer(username, api_key):
            success += 1
        else:
            failed += 1

    print("-" * 60)
    print(f"Done. Success: {success}, Failed: {failed}")


if __name__ == "__main__":
    main()
