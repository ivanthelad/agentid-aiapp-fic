import azure.functions as func
import logging
import json
import os
import datetime
import uuid
import contextlib
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
AGENT_DISPLAY_NAME = os.environ.get("AGENT_DISPLAY_NAME", "agentid-func-agent")

TOKEN_URL = f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token"

# --- Agent 365 Observability Setup ---
# ENABLE_A365_OBSERVABILITY_EXPORTER env var controls export target:
#   "true"  = export to Agent 365 service (requires Frontier preview)
#   "false" = export to console (default, for local validation)

_a365_enabled = False

try:
    from microsoft_agents_a365.observability.core import config as a365_config
    from microsoft_agents_a365.observability.core.middleware.baggage_builder import BaggageBuilder
    from microsoft_agents_a365.observability.core.invoke_agent_scope import InvokeAgentScope
    from microsoft_agents_a365.observability.core.invoke_agent_details import InvokeAgentDetails
    from microsoft_agents_a365.observability.core.execute_tool_scope import ExecuteToolScope
    from microsoft_agents_a365.observability.core.tool_call_details import ToolCallDetails
    from microsoft_agents_a365.observability.core.agent_details import AgentDetails
    from microsoft_agents_a365.observability.core.tenant_details import TenantDetails
    from microsoft_agents_a365.observability.core.request import Request
    from microsoft_agents_a365.observability.core.execution_type import ExecutionType

    def _token_resolver(agent_id: str, tenant_id: str) -> str | None:
        return None

    a365_config.configure(
        service_name=AGENT_DISPLAY_NAME or "agentid-func-agent",
        service_namespace="agentid.functions.demo",
        token_resolver=_token_resolver,
    )

    _agent_details = AgentDetails(
        agent_id=AGENT_IDENTITY_ID or "not-configured",
        agent_name=AGENT_DISPLAY_NAME or "agentid-func-agent",
        agent_blueprint_id=BLUEPRINT_CLIENT_ID or "not-configured",
        tenant_id=TENANT_ID or "not-configured",
    )
    _tenant_details = TenantDetails(tenant_id=TENANT_ID or "not-configured")
    _a365_enabled = True
    logging.info("A365 observability initialized")
except Exception as e:
    logging.warning("A365 observability init failed (non-fatal): %s", e)


def _baggage_scope(correlation_id):
    """Return A365 BaggageBuilder context or nullcontext if disabled."""
    if not _a365_enabled:
        return contextlib.nullcontext()
    return BaggageBuilder().tenant_id(TENANT_ID).agent_id(AGENT_IDENTITY_ID).correlation_id(correlation_id).build()


def _invoke_scope(correlation_id):
    """Return A365 InvokeAgentScope context or nullcontext if disabled."""
    if not _a365_enabled:
        return contextlib.nullcontext()
    return InvokeAgentScope.start(
        InvokeAgentDetails(details=_agent_details, session_id=correlation_id),
        _tenant_details,
        Request(content="write-status invocation", execution_type=ExecutionType.EVENT_TO_AGENT),
    )


def _tool_scope(blob_name):
    """Return A365 ExecuteToolScope context or nullcontext if disabled."""
    if not _a365_enabled:
        return contextlib.nullcontext()
    return ExecuteToolScope.start(
        ToolCallDetails(
            tool_name="blob_write",
            tool_type="azure_storage",
            tool_call_id=str(uuid.uuid4()),
            arguments=json.dumps({"account": STORAGE_ACCOUNT_NAME, "container": STORAGE_CONTAINER, "blob": blob_name}),
            description="Write heartbeat blob to Azure Storage",
        ),
        _agent_details,
        _tenant_details,
    )


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
    correlation_id = str(uuid.uuid4())
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

    # --- A365 Observability: wrap in InvokeAgentScope + ExecuteToolScope ---
    with _baggage_scope(correlation_id):
        with _invoke_scope(correlation_id):
            try:
                cred = AgentIdentityCredential()
                blob_name = f"heartbeat/functions-{now.strftime('%Y%m%dT%H%M%S')}.json"

                with _tool_scope(blob_name):
                    blob_service = BlobServiceClient(
                        account_url=f"https://{STORAGE_ACCOUNT_NAME}.blob.core.windows.net",
                        credential=cred,
                    )
                    container = blob_service.get_container_client(STORAGE_CONTAINER)
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
