"""
Agent ID Demo -- Microsoft Entra SDK for AgentID (Sidecar Pattern)

This app demonstrates ONE key concept:
  An AI agent running in K8s can get its own identity token and access
  Azure resources -- without any embedded credentials or auth logic.

How it works:
  1. The Entra SDK sidecar runs alongside this app in the same pod
  2. This app calls the sidecar's HTTP API to get tokens
  3. The sidecar handles the full token exchange chain:
     K8s SA JWT -> FIC exchange -> agent identity resource token

Architecture:
  Python App (port 8080) <-> Entra SDK Sidecar (port 5000) <-> Microsoft Entra ID

See: https://learn.microsoft.com/en-us/entra/msidweb/agent-id-sdk/overview

Environment variables (set via K8s ConfigMap):
  SIDECAR_URL          -- Entra SDK sidecar URL (default: http://localhost:5000)
  AGENT_IDENTITY_ID    -- Agent Identity's client ID
  STORAGE_ACCOUNT_NAME -- Azure Storage account name
  STORAGE_CONTAINER    -- Blob container name
  WRITE_INTERVAL       -- Seconds between heartbeat writes (default: 60)
"""

import os
import json
import time
import logging
import threading
from datetime import datetime, timezone

from flask import Flask, jsonify
import requests as http_requests

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("agent-demo")

# --- Config (all from K8s ConfigMap) ---
SIDECAR_URL = os.environ.get("SIDECAR_URL", "http://localhost:5000")
AGENT_IDENTITY_ID = os.environ.get("AGENT_IDENTITY_ID", "")
STORAGE_ACCOUNT_NAME = os.environ.get("STORAGE_ACCOUNT_NAME", "")
STORAGE_CONTAINER = os.environ.get("STORAGE_CONTAINER", "agent-demo")
WRITE_INTERVAL = int(os.environ.get("WRITE_INTERVAL", "60"))


# ---------------------------------------------------------------------------
# Core concept: calling the sidecar
#
# This is the ONLY auth-related code in the entire app.
# The sidecar does everything: K8s JWT -> FIC -> agent identity -> resource token
# ---------------------------------------------------------------------------
def get_sidecar_auth_header(service_name: str, agent_identity: str = None) -> str:
    """Get an Authorization header from the Entra SDK sidecar.

    Args:
        service_name: Matches a key in DownstreamApis__ config (e.g. "Storage")
        agent_identity: Agent Identity client ID. When set, the token's oid
                        becomes the agent identity (RBAC must be on this identity).
    """
    params = {}
    if agent_identity:
        params["AgentIdentity"] = agent_identity

    resp = http_requests.get(
        f"{SIDECAR_URL}/AuthorizationHeaderUnauthenticated/{service_name}",
        params=params,
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()["authorizationHeader"]


# ---------------------------------------------------------------------------
# Background blob writer -- proves the agent identity can access resources
# ---------------------------------------------------------------------------
write_status = {
    "last_result": "pending",
    "last_write_time": None,
    "last_error": None,
    "total_success": 0,
    "total_fail": 0,
}
_status_lock = threading.Lock()


def blob_writer_loop(account_name, container_name, agent_id, interval):
    """Writes a heartbeat blob every `interval` seconds.

    1. Calls sidecar to get a Storage token (with AgentIdentity)
    2. PUTs a blob via Azure Storage REST API
    3. Records success/failure for the /write-status endpoint
    """
    blob_base_url = f"https://{account_name}.blob.core.windows.net"

    while True:
        now = datetime.now(timezone.utc)
        blob_name = f"heartbeat/{now.strftime('%Y-%m-%dT%H-%M-%S')}.json"

        try:
            # Step 1: get token from sidecar
            auth_header = get_sidecar_auth_header("Storage", agent_identity=agent_id)

            # Step 2: write blob
            payload = json.dumps({
                "agent_identity_id": agent_id,
                "timestamp": now.isoformat(),
                "message": "Agent identity heartbeat",
            })

            resp = http_requests.put(
                f"{blob_base_url}/{container_name}/{blob_name}",
                data=payload,
                headers={
                    "Authorization": auth_header,
                    "x-ms-blob-type": "BlockBlob",
                    "Content-Type": "application/json",
                    "x-ms-version": "2024-11-04",
                },
                timeout=10,
            )
            resp.raise_for_status()

            with _status_lock:
                write_status["last_result"] = "success-write"
                write_status["last_write_time"] = now.isoformat()
                write_status["last_error"] = None
                write_status["total_success"] += 1
            logger.info("Blob written: %s", blob_name)

        except Exception as e:
            with _status_lock:
                write_status["last_result"] = "fail-write"
                write_status["last_write_time"] = now.isoformat()
                write_status["last_error"] = str(e)
                write_status["total_fail"] += 1
            logger.error("Blob write failed: %s", e)

        time.sleep(interval)


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.route("/health")
def health():
    return jsonify({"status": "ok"})


@app.route("/write-status")
def get_write_status():
    """Returns the cached blob write status (no blob call on each request)."""
    with _status_lock:
        return jsonify(dict(write_status))


@app.route("/sidecar-health")
def sidecar_health():
    """Check if the Entra SDK sidecar is responsive."""
    try:
        resp = http_requests.get(f"{SIDECAR_URL}/healthz", timeout=5)
        return jsonify({"sidecar_status": "healthy", "status_code": resp.status_code})
    except Exception as e:
        return jsonify({"sidecar_status": "unhealthy", "error": str(e)}), 503


@app.route("/")
def index():
    return jsonify({
        "app": "Agent ID Demo (Sidecar Pattern)",
        "concept": "AI agent with its own identity -- zero auth code",
        "endpoints": {
            "/write-status": "Show blob write results (proves resource access)",
            "/health": "App liveness",
            "/sidecar-health": "Sidecar container health",
        },
    })


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
def start_background_writer():
    if not STORAGE_ACCOUNT_NAME:
        logger.warning("STORAGE_ACCOUNT_NAME not set -- blob writer disabled")
        return
    if not AGENT_IDENTITY_ID:
        logger.warning("AGENT_IDENTITY_ID not set -- blob writer disabled")
        return

    def _wait_and_start():
        # Wait for sidecar to be ready before first write
        for i in range(30):
            try:
                http_requests.get(f"{SIDECAR_URL}/healthz", timeout=2)
                logger.info("Sidecar ready, starting blob writer")
                break
            except Exception:
                time.sleep(2)
        blob_writer_loop(STORAGE_ACCOUNT_NAME, STORAGE_CONTAINER, AGENT_IDENTITY_ID, WRITE_INTERVAL)

    t = threading.Thread(target=_wait_and_start, daemon=True)
    t.start()
    logger.info(
        "Background blob writer starting (interval=%ds, sidecar=%s)",
        WRITE_INTERVAL, SIDECAR_URL,
    )


start_background_writer()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
