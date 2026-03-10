---
name: agent-id
description: "Microsoft Entra Agent ID expertise -- blueprints, agent identities, workload identity federation, token exchange, governance patterns, and Graph API usage. Use this skill when working with Agent ID concepts, creating or modifying Agent ID scripts, writing documentation about agent identities, or debugging token exchange flows."
---

# Microsoft Entra Agent ID — Knowledge Base

## Three-Layer Mental Model

```
Blueprint             — governance and policy    (who agents CAN be)
Agent Identity        — auditable principal      (who the agent IS)
Hosting App           — execution environment    (WHERE the agent runs)
```

Your hosting app is replaceable; the agent identity is not. The blueprint sets boundaries. The agent identity acts within them. The app is just where code runs.

## End-to-End Flows

### AKS Flow (7 steps)
1. Create Agent Identity Blueprint (governance team, Graph API, sponsors required, 30s replication delay)
2. Register downstream APIs (API owners -- app registrations or built-in Azure scopes)
3. Create Agent Identity (dev team, linked via `agentAppId`, sponsors required)
4. Assign RBAC to agent identity (resource owners -- on agent identity, NOT blueprint)
5. Configure AKS Workload Identity (OIDC issuer + FIC on blueprint + SA with `azure.workload.identity/use` label)
6. Deploy with Entra SDK sidecar (companion container, ConfigMap, TCP probes, indexed scopes)
7. Runtime: App → sidecar HTTP API → K8s JWT → FIC exchange → agent identity resource token

See: `docs/flow-aks-agent-identity.md`

### Functions Flow (7 steps)
1. Create Agent Identity Blueprint (same as AKS)
2. Register downstream APIs (same)
3. Create Agent Identity (same)
4. Assign RBAC to agent identity (same)
5. Configure Function App with MSI + FIC (MSI principal as FIC subject, Entra-to-Entra federation)
6. Deploy Entra SDK (sidecar or SDK library)
7. Runtime: MSI token → FIC exchange with fmi_path → agent identity resource token

See: `docs/functions-agent-identity.md`

### Key difference: Federation source
- **AKS:** External OIDC issuer (AKS cluster) → K8s service account JWT
- **Functions:** Internal Entra issuer → Managed Identity token

Both produce identical agent identity tokens with the same claims.

## Core Concepts

### Object Hierarchy

1. **Agent Identity Blueprint** — An Entra application registration (`@odata.type: Microsoft.Graph.AgentIdentityBlueprint`). The template/class for agents.
   - Created via: `POST https://graph.microsoft.com/beta/applications/`
   - Holds the Federated Identity Credential (FIC)
   - Has a designated sponsor (required)
   - Target for conditional access policies
   - 1:N relationship with agent identities

2. **Blueprint Service Principal** — The service principal for the blueprint app registration.
   - Created via: `POST https://graph.microsoft.com/beta/serviceprincipals/graph.agentIdentityBlueprintPrincipal`
   - Must be created after the blueprint app registration

3. **Agent Identity** — A runtime service principal created from a blueprint. Has no credentials of its own.
   - Created via: `POST https://graph.microsoft.com/beta/serviceprincipals/Microsoft.Graph.AgentIdentity`
   - Uses `agentAppId` field (NOT `agentIdentityBlueprintId`) to link to the blueprint's `appId`
   - Created using the blueprint's token (not management app token)

4. **Agent User / Digital Colleague** (optional) — A `microsoft.graph.agentUser` User object with own mailbox, Teams, calendar.
   - Created via: `POST https://graph.microsoft.com/beta/users`
   - Linked via `identityParentId` pointing to the agent identity
   - Requires `User.ReadWrite.All` permission (preview)

## API Patterns

### All Graph API calls use `/beta` endpoint (Agent ID is in preview)

### Creating a Blueprint
```http
POST https://graph.microsoft.com/beta/applications/
Content-Type: application/json
OData-Version: 4.0

{
  "@odata.type": "Microsoft.Graph.AgentIdentityBlueprint",
  "displayName": "my-agent-blueprint",
  "sponsors@odata.bind": [
    "https://graph.microsoft.com/v1.0/groups/<sponsor-group-id>"
  ]
}
```

### Creating an Agent Identity
```http
POST https://graph.microsoft.com/beta/serviceprincipals/Microsoft.Graph.AgentIdentity
Content-Type: application/json
OData-Version: 4.0
Authorization: Bearer <BLUEPRINT_TOKEN>

{
  "displayName": "my-agent-identity",
  "agentAppId": "<blueprint-appId>",
  "sponsors@odata.bind": [
    "https://graph.microsoft.com/v1.0/groups/<sponsor-group-id>"
  ]
}
```

**IMPORTANT:** The field is `agentAppId`, and its value is the blueprint's `appId` (NOT the object ID).

### Adding a FIC for Kubernetes
```http
POST https://graph.microsoft.com/beta/applications/<blueprint-object-id>/federatedIdentityCredentials
Content-Type: application/json

{
  "name": "k8s-workload-identity",
  "issuer": "<AKS_OIDC_ISSUER_URL>",
  "subject": "system:serviceaccount:<namespace>:<service-account-name>",
  "audiences": ["api://AzureADTokenExchange"]
}
```

### Adding a FIC for Managed Identity (Functions/App Service)
```http
POST https://graph.microsoft.com/beta/applications/<blueprint-object-id>/federatedIdentityCredentials
Content-Type: application/json

{
  "name": "msi-workload-identity",
  "issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0",
  "subject": "<managed-identity-principal-id>",
  "audiences": ["api://AzureADTokenExchange"]
}
```

## Token Exchange Flows

### Kubernetes (single-step, uses external OIDC issuer)
```
POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token

client_id=<BLUEPRINT_CLIENT_ID>
&scope=<RESOURCE_SCOPE>
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion=<K8S_SA_JWT>
&grant_type=client_credentials
```

### Azure Functions (two-step, Entra-to-Entra federation)
**Step 1 — MSI to Blueprint exchange token (T1):**
```
client_id=<BLUEPRINT_CLIENT_ID>
&scope=api://AzureADTokenExchange/.default
&fmi_path=<AGENT_IDENTITY_ID>
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion=<MSI_TOKEN>
&grant_type=client_credentials
```

**Step 2 — T1 to resource token (TR):**
```
client_id=<AGENT_IDENTITY_ID>
&scope=https://graph.microsoft.com/.default
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion=<T1>
&grant_type=client_credentials
```

### Digital Colleague (three-step, uses `user_fic` grant type)
Steps 1-2 same as Functions, then:
**Step 3 — Agent User token:**
```
client_id=<AGENT_IDENTITY_ID>
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion=<BLUEPRINT_FIC_TOKEN>
&grant_type=user_fic
&requested_token_use=on_behalf_of
&scope=https://graph.microsoft.com/.default
&username=<AGENT_USER_UPN>
&user_federated_identity_credential=<AGENT_IDENTITY_FIC_TOKEN>
```

## Persona Separation

| Responsibility | Central AI Governance | Agent Dev Team |
|---|---|---|
| Create blueprints | ✅ | ❌ |
| Configure FIC | ✅ | ❌ |
| Create agent identities | ✅ (via blueprint token) | ❌ (request via central team) |
| Deploy app with WIF | ❌ | ✅ |
| Manage conditional access | ✅ | ❌ |
| Create access packages | ✅ | ❌ |
| Request access packages | ❌ | ✅ |

### Required Entra Roles (Central Team Only)
- Agent ID Administrator
- Privileged Role Administrator  
- Cloud Application Administrator
- Identity Governance Administrator
- Conditional Access Administrator

### Dev Team Roles
None — all operations use the blueprint token.

## Common Gotchas

1. **`agentAppId` not `agentIdentityBlueprintId`** — The field for linking agent identity to blueprint is `agentAppId`.
2. **OData-Version header** — Blueprint creation requires `OData-Version: 4.0` header.
3. **Wait after creation** — Wait 20-30 seconds after creating blueprints/identities for replication.
4. **Beta API only** — All Agent ID endpoints are under `/beta`, not `/v1.0`.
5. **FIC on blueprint, not agent identity** — Agent identities have NO credentials of their own.
6. **Sponsor is required** — Both blueprints and agent identities must have a sponsor. API returns `Request_BadRequest` without them.
7. **Blueprint credential for agent identity creation** — The POST to create an agent identity must be authenticated with the blueprint's token, not the management app.
8. **Blueprint `id` == `appId`** — For agentIdentityBlueprint type apps, the `id` and `appId` are the SAME GUID (unlike regular app registrations).
9. **Agent ID APIs reject `Directory.AccessAsUser.All`** — Cannot use `az account get-access-token` for delegated tokens. Must use a dedicated management app with `Application.ReadWrite.All` + `Agent ID Administrator` role + client_credentials flow.
10. **URL encoding required** — Secrets with special characters (`~`, `+`, etc.) break `-d` form data in curl. Use `--data-urlencode` for all token request parameters.
11. **`fmi_path` scope restriction** — `fmi_path` only works with `api://AzureADTokenExchange/.default` scope. Requesting resource scopes (e.g., `https://storage.azure.com/.default`) directly with fmi_path returns AADSTS70066.
12. **Agent identity `servicePrincipalType`** — Agent identities are SPs of type `ServiceIdentity` (not `Application`). Azure RBAC accepts this type for role assignments.
13. **RBAC goes on agent identity, not blueprint** — When using the sidecar with `AgentIdentity` parameter, the resulting token's `oid` is the agent identity. RBAC roles for resource access must be assigned to the agent identity, not the blueprint.
14. **`fmi_path` is mandatory for token exchange** — AADSTS82008: "All agentic applications requesting a token exchange token must include the fmipath parameter." The `azure-identity` SDK's `ClientAssertionCredential` does NOT support `fmi_path`. Use raw HTTP POST to the token endpoint with the `fmi_path` form field, or use the `requests` library.
15. **Functions hosting storage needs shared key access** — Azure Functions requires `allowSharedKeyAccess=true` on its hosting storage account to create file shares. Subscription policies that disable shared key access will cause `az functionapp create` to fail with 403.
16. **Register Microsoft.Web provider** — Test/new subscriptions may not have `Microsoft.Web` registered. Run `az provider register --namespace Microsoft.Web --wait` before creating Function Apps.
17. **`fmi_path` must be a POST body parameter, not a query param** — The MS docs' `FmiTransport` example uses `AppendQuery` to add `fmi_path` as a URL query parameter, but the Entra token endpoint requires it in the form-urlencoded POST body. Using query params causes AADSTS82008. The correct approach is to intercept POST requests to `oauth2/v2.0/token` and append `&fmi_path=<id>` to the form body.
18. **FIC names must be unique per blueprint** — When adding multiple FICs to the same blueprint (e.g., one for AKS OIDC, one for Python MI, one for .NET MI), each needs a unique `name`. Use descriptive names like `k8s-workload-identity`, `msi-workload-identity`, `msi-workload-identity-dotnet`.

## Microsoft Entra SDK for AgentID (Sidecar Pattern)

The official containerised service for handling Agent ID token management. Runs as a companion container alongside your application in the same pod.

### Image
```
mcr.microsoft.com/entra-sdk/auth-sidecar:1.0.0-azurelinux3.0-distroless
```

### Architecture
```
Pod
├── Your App (any language, port 8080)
│   └── calls http://localhost:5000/... for tokens
└── entra-sdk-sidecar (port 5000)
    └── handles FIC exchange, fmi_path, resource tokens, caching
```

### Key Endpoints
- `/AuthorizationHeaderUnauthenticated/{service}?AgentIdentity=<id>` — get token for downstream API (autonomous agent, no inbound user token)
- `/AuthorizationHeader/{service}?AgentIdentity=<id>` — get token with OBO (requires inbound bearer token)
- `/DownstreamApiUnauthenticated/{service}` — proxy API call with automatic token
- `/Validate` — validate inbound bearer token and return claims
- `/healthz` — health probe

### Sidecar Configuration (K8s env vars)
```yaml
# Core Entra ID settings
AzureAd__TenantId: "<tenant-id>"
AzureAd__ClientId: "<blueprint-app-id>"
AzureAd__ClientCredentials__0__SourceType: "SignedAssertionFilePath"

# Downstream API: Storage
DownstreamApis__Storage__BaseUrl: "https://<account>.blob.core.windows.net"
DownstreamApis__Storage__Scopes__0: "https://storage.azure.com/.default"   # NOTE: indexed format!
DownstreamApis__Storage__RequestAppToken: "true"

# Downstream API: Agent Token (for displaying claims)
DownstreamApis__AgentToken__BaseUrl: "https://login.microsoftonline.com"
DownstreamApis__AgentToken__Scopes__0: "api://AzureADTokenExchange/.default"
DownstreamApis__AgentToken__RequestAppToken: "true"
```

### Sidecar Gotchas (Discovered During Implementation)

1. **Scopes must use indexed format** — ASP.NET Core arrays in env vars require `Scopes__0`, `Scopes__1`, etc. Using `Scopes` (without index) causes "No scopes found" 400 errors.
2. **Use TCP socket probes, not HTTP** — The sidecar's `/healthz` endpoint returns 400 to K8s HTTP probes (likely due to JWT middleware intercepting the request). TCP probes on port 5000 work reliably.
3. **`ASPNETCORE_URLS` is required** — Set `ASPNETCORE_URLS=http://+:5000` explicitly. The sidecar image defaults to port 8080 (`HTTP_PORTS`), which conflicts with app containers.
4. **AKS workload identity webhook injects env vars** — When the pod has `azure.workload.identity/use: "true"` label, the webhook automatically injects `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_FEDERATED_TOKEN_FILE` into ALL containers (including the sidecar). The `SignedAssertionFilePath` credential type reads the token from this webhook-projected path.
5. **Token caching** — The sidecar caches tokens. Calls with and without `AgentIdentity` may return the same cached token if the cache key matches. This is expected behaviour.
6. **Sidecar handles fmi_path internally** — When `AgentIdentity` query parameter is provided, the sidecar automatically includes `fmi_path` in the token exchange request. Your app never needs to deal with fmi_path directly.

### Agent Identity Query Parameters
| Parameters | Pattern | Token `oid` |
|---|---|---|
| `AgentIdentity` only | Autonomous agent | Agent identity |
| `AgentIdentity` + `AgentUsername` | Interactive agent (by UPN) | User |
| `AgentIdentity` + `AgentUserId` | Interactive agent (by OID) | User |
| (none) | Standard OBO/client_credentials | Blueprint SP |

### Python Integration Pattern
```python
import requests

SIDECAR_URL = "http://localhost:5000"

def get_agent_token(service_name, agent_identity_id):
    resp = requests.get(
        f"{SIDECAR_URL}/AuthorizationHeaderUnauthenticated/{service_name}",
        params={"AgentIdentity": agent_identity_id},
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()["authorizationHeader"]
```

### References
- [SDK Overview](https://learn.microsoft.com/en-us/entra/msidweb/agent-id-sdk/overview)
- [Installation](https://learn.microsoft.com/en-us/entra/msidweb/agent-id-sdk/installation)
- [Configuration](https://learn.microsoft.com/en-us/entra/msidweb/agent-id-sdk/configuration)
- [Endpoints](https://learn.microsoft.com/en-us/entra/msidweb/agent-id-sdk/endpoints)
- [Agent Identities](https://learn.microsoft.com/en-us/entra/msidweb/agent-id-sdk/agent-identities)
- [Python Integration](https://learn.microsoft.com/en-us/entra/msidweb/agent-id-sdk/scenarios/using-from-python)
- [Autonomous Batch Processing](https://learn.microsoft.com/en-us/entra/msidweb/agent-id-sdk/scenarios/agent-autonomous-batch)

## References

- [Entra Agent ID Docs](https://learn.microsoft.com/entra/agent-id/)
- [astaykov/entra-agent-id-preview-guide](https://github.com/astaykov/entra-agent-id-preview-guide)
- [Christian Posta — Entra Agent ID on K8s](https://blog.christianposta.com/entra-agent-id-agw/)
- [Agent OAuth Protocols](https://learn.microsoft.com/entra/agent-id/identity-platform/agent-oauth-protocols)

## Updating This Skill

When you discover new information about Agent ID (API changes, new fields, behavioral quirks, error resolutions), add it to the appropriate section above. This skill should be the single source of truth for Agent ID development patterns.
