"""Alertmanager -> Feishu webhook adapter."""
import os
import sys
from datetime import datetime
from flask import Flask, request, jsonify
import requests

app = Flask(__name__)
FEISHU_WEBHOOK = os.environ.get("FEISHU_WEBHOOK", "").strip()


def format_alert(alert):
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})
    status = alert.get("status", "firing")

    severity = labels.get("severity", "warning")
    alertname = labels.get("alertname", "Unknown")
    instance = labels.get("instance", "-")
    summary = annotations.get("summary", "")
    description = annotations.get("description", "")

    starts_at = alert.get("startsAt", "")
    try:
        dt = datetime.fromisoformat(starts_at.replace("Z", "+00:00"))
        starts_at = dt.strftime("%Y-%m-%d %H:%M:%S UTC")
    except Exception:
        pass

    emoji = {"firing": "🔥", "resolved": "✅"}.get(status, "⚠️")
    color = {"critical": "red", "warning": "orange"}.get(severity, "blue")

    return {
        "tag": "div",
        "text": {
            "tag": "lark_md",
            "content": (
                f"**{emoji} [{status.upper()}] {alertname}**\n"
                f"**Severity**: <font color='{color}'>{severity}</font>\n"
                f"**Instance**: {instance}\n"
                f"**Summary**: {summary}\n"
                f"**Description**: {description}\n"
                f"**Time**: {starts_at}"
            ),
        },
    }


@app.route("/alert", methods=["POST"])
def alert():
    if not FEISHU_WEBHOOK:
        return jsonify({"error": "FEISHU_WEBHOOK env var not set"}), 500

    data = request.get_json(force=True, silent=True) or {}
    alerts = data.get("alerts", [])
    if not alerts:
        return jsonify({"ok": True, "msg": "no alerts"}), 200

    elements = []
    for a in alerts:
        elements.append(format_alert(a))
        elements.append({"tag": "hr"})
    if elements and elements[-1].get("tag") == "hr":
        elements.pop()

    card = {
        "msg_type": "interactive",
        "card": {
            "config": {"wide_screen_mode": True},
            "header": {
                "title": {
                    "tag": "plain_text",
                    "content": f"APISIX Alert ({len(alerts)})",
                },
                "template": "red" if any(a.get("status") == "firing" for a in alerts) else "green",
            },
            "elements": elements,
        },
    }

    try:
        resp = requests.post(FEISHU_WEBHOOK, json=card, timeout=5)
        return jsonify({"ok": resp.ok, "status": resp.status_code}), 200
    except Exception as e:
        print(f"Failed to send to Feishu: {e}", file=sys.stderr)
        return jsonify({"error": str(e)}), 500


@app.route("/healthz")
def healthz():
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
