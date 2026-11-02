"""SOAR service (runs as a container on ECS Fargate).

Flow: Elastic Security rule fires -> webhook connector POSTs here (through the NLB)
      -> playbook decides on a response -> result is stored in RDS PostgreSQL.
      -> /metrics exposes the SOAR's own health for Prometheus (monitoring covers the SOAR itself).
Response action for high/critical alerts: isolate the host via Elastic Defend.
"""
import hmac
import json
import logging
import os
import time

import boto3
import psycopg2
import psycopg2.extras
import requests
from flask import Flask, Response, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("soar")
app = Flask(__name__)

DB_HOST = os.environ["DB_HOST"]
DB_NAME = os.environ.get("DB_NAME", "soar")
DB_SECRET_ARN = os.environ["DB_SECRET_ARN"]
WEBHOOK_TOKEN = os.environ["WEBHOOK_TOKEN"]
KIBANA_URL = os.environ.get("KIBANA_URL", "")
KIBANA_API_KEY = os.environ.get("KIBANA_API_KEY", "")
REGION = os.environ.get("AWS_REGION", "eu-central-1")

ALERTS = Counter("soar_alerts_total", "Alerts processed", ["severity", "action"])
ACTION_FAILURES = Counter("soar_action_failures_total", "Response actions that failed", ["action"])
UNAUTHORIZED = Counter("soar_webhook_unauthorized_total", "Webhook calls with a wrong token")
DB_ERRORS = Counter("soar_db_errors_total", "Database errors")
DURATION = Histogram("soar_webhook_duration_seconds", "Time to handle one webhook call")

_secret_cache = {}
_db_ready = False


def db_credentials():
    if not _secret_cache:
        sm = boto3.client("secretsmanager", region_name=REGION)
        _secret_cache.update(json.loads(sm.get_secret_value(SecretId=DB_SECRET_ARN)["SecretString"]))
    return _secret_cache


def db():
    c = db_credentials()
    return psycopg2.connect(host=DB_HOST, dbname=DB_NAME, user=c["username"],
                            password=c["password"], sslmode="require", connect_timeout=5)


def init_db():
    global _db_ready
    if _db_ready:
        return
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS alerts (
              id SERIAL PRIMARY KEY,
              received_at TIMESTAMPTZ DEFAULT now(),
              rule TEXT, severity TEXT, host TEXT, agent_id TEXT,
              action TEXT, status TEXT, raw JSONB
            )""")
    _db_ready = True


def isolate_host(agent_id, reason):
    """Returns (ok, text)."""
    if not (KIBANA_URL and KIBANA_API_KEY and agent_id):
        return True, "skipped: Elastic Defend not configured"
    try:
        r = requests.post(
            f"{KIBANA_URL}/api/endpoint/action/isolate",
            headers={"kbn-xsrf": "true", "Authorization": f"ApiKey {KIBANA_API_KEY}"},
            json={"endpoint_ids": [agent_id], "comment": f"SOAR auto-isolation: {reason}"},
            timeout=10,
        )
        return r.ok, f"isolate http {r.status_code}"
    except requests.RequestException as exc:
        return False, f"isolate error: {exc.__class__.__name__}"


def run_playbook(alert):
    sev = (alert["severity"] or "").lower()
    if sev in ("high", "critical"):
        ok, text = isolate_host(alert["agent_id"], alert["rule"])
        if not ok:
            ACTION_FAILURES.labels("isolate_host").inc()
        return "isolate_host", text
    return "notify_only", "logged for analyst review"


@app.get("/health")
def health():
    return "ok", 200


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


@app.post("/webhook")
def webhook():
    start = time.time()
    token = request.headers.get("X-Webhook-Token", "")
    if not hmac.compare_digest(token, WEBHOOK_TOKEN):
        UNAUTHORIZED.inc()
        return jsonify(error="unauthorized"), 401
    raw = request.get_json(silent=True) or {}
    alert = {
        "rule": raw.get("rule", {}).get("name") or raw.get("rule_name") or "unknown",
        "severity": raw.get("rule", {}).get("severity") or raw.get("severity") or "low",
        "host": raw.get("host", {}).get("name") or raw.get("host") or "unknown",
        "agent_id": raw.get("agent", {}).get("id") or raw.get("agent_id"),
    }
    action, status = run_playbook(alert)
    ALERTS.labels(str(alert["severity"]).lower(), action).inc()
    try:
        init_db()
        with db() as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO alerts (rule, severity, host, agent_id, action, status, raw) "
                "VALUES (%s,%s,%s,%s,%s,%s,%s)",
                (alert["rule"], alert["severity"], str(alert["host"]), alert["agent_id"],
                 action, status, psycopg2.extras.Json(raw)),
            )
    except Exception as exc:
        DB_ERRORS.inc()
        log.error("database error: %s", exc)
        return jsonify(error="database unavailable", action=action, status=status), 503
    finally:
        DURATION.observe(time.time() - start)
    log.info("alert=%s severity=%s action=%s status=%s", alert["rule"], alert["severity"], action, status)
    return jsonify(action=action, status=status), 200
