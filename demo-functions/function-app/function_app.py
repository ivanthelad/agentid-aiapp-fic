import azure.functions as func
import logging
import json
import os
import datetime
import requests as http_requests

from azure.identity import ManagedIdentityCredential
from azure.storage.blob import BlobServiceClient
from azure.core.credentials import AccessToken, TokenCredential

app = func.FunctionApp()

# --- Configuration (from Function App settings, populated by scripts) ---
TENANT_ID = os.environ.get("TENANT_ID", "")
BLUEPRINT_CLIENT_ID = os.environ.get("BLUEPRINT_CLIENT_ID", "")
MI_CLIENT_ID = os.environ.get("MI_CLIENT_ID", "")
AGENT_IDENTITY_ID = os.environ.get("AGENT_IDENTITY_ID", "")
STORAGE_ACCOUNT_NAME = os.environ.get("STORAGE_ACCOUNT_NAME", "")
STORAGE_CONTAINER = os.environ.get("STORAGE_CONTAINER", "agent-demo")

TOKEN_URL = f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token"


class AgentIdentityCredential(TokenCredential):
    """
    Two-step token exchange for Agent ID on Azure Functions.

    Step 1: MSI assertion → Blueprint exchange token (T1)
            Requires fmi_path parameter pointing to the agent identity.
            azure-identity's ClientAssertionCredential does NOT support fmi_path,
            so we use raw HTTP POST to the token endpoint.

    Step 2: T1 → Resource token (TR)
            Standard client_credentials grant with T1 as client_assertion.
    """

    def __init__(self):
        self._msi = ManagedIdentityCredential(client_id=MI_CLIENT_ID)

    def _exchange_token(self, assertion, client_id, scope, fmi_path=None):
        """Exchange a client assertion for a token via the Entra token endpoint."""
        data = {
            "client_id": client_id,
            "scope": scope,
            "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
            "client_assertion": assertion,
            "grant_type": "client_credentials",
        }
        if fmi_path:
            data["fmi_path"] = fmi_path

        resp = http_requests.post(TOKEN_URL, data=data, timeout=30)
        if resp.status_code != 200:
            raise Exception(f"Token exchange failed ({resp.status_code}): {resp.text}")

        token_data = resp.json()
        return token_data["access_token"], token_data.get("expires_in", 3600)

    def get_token(self, *scopes, **kwargs):
        scope = scopes[0] if scopes else "https://storage.azure.com/.default"

        # Step 1: MSI → T1 (with fmi_path)
        msi_token = self._msi.get_token("api://AzureADTokenExchange/.default")
        t1, _ = self._exchange_token(
            assertion=msi_token.token,
            client_id=BLUEPRINT_CLIENT_ID,
            scope="api://AzureADTokenExchange/.default",
            fmi_path=AGENT_IDENTITY_ID,
        )

        # Step 2: T1 → TR (resource token)
        tr, expires_in = self._exchange_token(
            assertion=t1,
            client_id=AGENT_IDENTITY_ID,
            scope=scope,
        )

        return AccessToken(tr, int(datetime.datetime.utcnow().timestamp()) + expires_in)


WRITE_THROTTLE_SUCCESS = 60
WRITE_THROTTLE_FAIL = 5
_last_write = {
    "status": None,
    "blob": None,
    "timestamp": None,
    "error": None,
}


# --- HTTP: write-status (throttled blob write) ---
@app.route(route="write-status", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def write_status_endpoint(req: func.HttpRequest) -> func.HttpResponse:
    """Writes a blob via two-step token exchange. Throttled: 60s on success, 5s on failure."""
    now = datetime.datetime.utcnow()
    result = {
        "source": "azure-functions",
        "agent_identity": AGENT_IDENTITY_ID or "(not configured)",
        "storage_account": STORAGE_ACCOUNT_NAME or "(not configured)",
    }

    # Return cached result if within throttle window
    if _last_write["timestamp"]:
        elapsed = (now - datetime.datetime.fromisoformat(_last_write["timestamp"])).total_seconds()
        cooldown = WRITE_THROTTLE_SUCCESS if _last_write["status"] == "success-write" else WRITE_THROTTLE_FAIL
        if elapsed < cooldown:
            result.update(_last_write)
            result["throttled"] = True
            result["next_write_in"] = int(cooldown - elapsed)
            return func.HttpResponse(json.dumps(result, indent=2), mimetype="application/json")

    if not all([TENANT_ID, BLUEPRINT_CLIENT_ID, MI_CLIENT_ID, AGENT_IDENTITY_ID, STORAGE_ACCOUNT_NAME]):
        missing = [k for k, v in {
            "TENANT_ID": TENANT_ID, "BLUEPRINT_CLIENT_ID": BLUEPRINT_CLIENT_ID,
            "MI_CLIENT_ID": MI_CLIENT_ID, "AGENT_IDENTITY_ID": AGENT_IDENTITY_ID,
            "STORAGE_ACCOUNT_NAME": STORAGE_ACCOUNT_NAME,
        }.items() if not v]
        result["status"] = "fail-write"
        result["error"] = f"Missing config: {', '.join(missing)}"
        return func.HttpResponse(json.dumps(result, indent=2), mimetype="application/json", status_code=500)

    try:
        cred = AgentIdentityCredential()
        blob_service = BlobServiceClient(
            account_url=f"https://{STORAGE_ACCOUNT_NAME}.blob.core.windows.net",
            credential=cred,
        )
        container = blob_service.get_container_client(STORAGE_CONTAINER)

        blob_name = f"heartbeat/functions-{now.strftime('%Y%m%dT%H%M%S')}.json"
        data = json.dumps({
            "source": "azure-functions",
            "timestamp": now.isoformat(),
            "agent_identity": AGENT_IDENTITY_ID,
            "blueprint": BLUEPRINT_CLIENT_ID,
        })
        container.upload_blob(blob_name, data, overwrite=True)

        _last_write["status"] = "success-write"
        _last_write["blob"] = blob_name
        _last_write["timestamp"] = now.isoformat()
        _last_write["error"] = None
        result.update(_last_write)
        result["throttled"] = False
        logging.info("Blob write succeeded: %s", blob_name)

    except Exception as e:
        _last_write["status"] = "fail-write"
        _last_write["timestamp"] = now.isoformat()
        _last_write["error"] = str(e)
        _last_write["blob"] = None
        result.update(_last_write)
        result["throttled"] = False
        logging.error("Blob write failed: %s", e)
        return func.HttpResponse(json.dumps(result, indent=2), mimetype="application/json", status_code=500)

    return func.HttpResponse(json.dumps(result, indent=2), mimetype="application/json")


# --- HTTP: health ---
@app.route(route="health", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def health(req: func.HttpRequest) -> func.HttpResponse:
    """Liveness probe."""
    return func.HttpResponse("ok", mimetype="text/plain")
