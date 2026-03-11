# Agent ID Demo — .NET Azure Functions with SDK-Native fmi_path

This is the C# counterpart of the [Python Functions demo](../demo-functions/README.md). It uses Azure.Identity with a custom `FmiTransport` class that injects `fmi_path` into the POST body -- an SDK-native approach not available in Python. It is fully self-contained -- no other demos need to be run first.

## Architecture

```mermaid
flowchart LR
    subgraph persona1["Persona 1: Central AI Governance"]
        P1_00["00-setup-prerequisites.sh\nMgmt App + Sponsor Group"]
        P1_01["01-provision-function.sh\nFunction App (.NET 8) + MI"]
        P1_02["02-create-blueprint.sh\nBlueprint + MSI FIC"]
        P1_03["03-create-agent-id.sh\nAgent Identity"]
    end

    subgraph persona2["Persona 2: Agent Dev Team"]
        P2_04["04-setup-storage.sh\nStorage + RBAC"]
        P2_05["05-deploy-function.sh\nBuild + Deploy"]
        P2_06["06-verify.sh\nTest endpoints"]
    end

    P1_00 --> P1_01 --> P1_02 --> P1_03 --> P2_04 --> P2_05 --> P2_06
```

## Prerequisites

- Azure CLI 2.x with the isolated test tenant session:
  ```bash
  source ./az-agentid-setup.sh
  ```
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- [Azure Functions Core Tools](https://learn.microsoft.com/azure/azure-functions/functions-run-local) v4+ (`func`)
- `jq` and `python3` installed
- Current user must be Global Admin or Privileged Role Admin (for 00-setup-prerequisites.sh)

## Getting Started

```bash
cp .env.template .env
```

## How `.env` works

| Script | Writes to `.env` |
|---|---|
| `00-setup-prerequisites.sh` | MGMT_APP_ID, MGMT_APP_SECRET, SPONSOR_GROUP_ID |
| `01-provision-function.sh` | Function App config, MI_CLIENT_ID, MI_PRINCIPAL_ID |
| `02-create-blueprint.sh` | TENANT_ID, BLUEPRINT_OBJECT_ID, BLUEPRINT_APP_ID, BLUEPRINT_SP_ID |
| `03-create-agent-id.sh` | Agent identity IDs (Persona 1) |
| `04-setup-storage.sh` | Storage account name |
| `05-deploy-function.sh` | (read-only) |
| `06-verify.sh` | (read-only) |

## Execution Order

### Persona 1 — Central AI Governance Team

```bash
cd demo-functions-dotnet

# 0. Create management app + sponsor group (one-time per tenant)
bash persona-1-governance/00-setup-prerequisites.sh

# 1. Create Function App (.NET 8) + User-Assigned Managed Identity
bash persona-1-governance/01-provision-function.sh

# 2. Create blueprint + add FIC for managed identity
bash persona-1-governance/02-create-blueprint.sh

# 3. Create agent identity from blueprint
bash persona-1-governance/03-create-agent-id.sh

# Hand off .env to Persona 2
```

### Persona 2 — Agent Development Team

```bash
cd demo-functions-dotnet

# 4. Create storage account and assign RBAC to agent identity
bash persona-2-developer/04-setup-storage.sh

# 5. Build and deploy .NET function code + configure app settings
bash persona-2-developer/05-deploy-function.sh

# 6. Verify endpoints
bash persona-2-developer/06-verify.sh
```

## Two-Step Token Exchange

Uses the same two-step MSI → Blueprint → Resource exchange. See [docs/functions-agent-identity.md](../docs/functions-agent-identity.md) for the detailed flow.

### The FmiTransport Pattern

`FmiTransport` is a custom `HttpClientTransport` that intercepts POST requests to `oauth2/v2.0/token` and appends `fmi_path` to the form body. The Entra token endpoint requires `fmi_path` in the POST body (form-urlencoded), not as a URL query parameter.

```csharp
public class FmiTransport(string agentIdentityId) : HttpClientTransport()
{
    public override ValueTask ProcessAsync(HttpMessage message)
    {
        InjectFmiPath(message);
        return base.ProcessAsync(message);
    }

    private void InjectFmiPath(HttpMessage message)
    {
        if (message.Request.Method != RequestMethod.Post) return;
        var uri = message.Request.Uri.ToString();
        if (!uri.Contains("oauth2/v2.0/token")) return;

        using var ms = new MemoryStream();
        message.Request.Content.WriteTo(ms, default);
        var body = Encoding.UTF8.GetString(ms.ToArray());
        body += "&fmi_path=" + Uri.EscapeDataString(agentIdentityId);
        message.Request.Content = RequestContent.Create(Encoding.UTF8.GetBytes(body));
    }
}
```

### Three Credential Classes

| Class | Role | Input | Output |
|---|---|---|---|
| `AgentIdentityBlueprintCredential` | MSI → blueprint token | MSI token as assertion | Blueprint exchange token |
| `FmiTransport` | Injects `fmi_path` into POST body | HTTP request | Modified HTTP request |
| `AgentIdentityCredential` | Full two-step exchange | Config values | Resource token (oid = agent identity) |

## What the Function App Does

A .NET Azure Function with zero secrets -- all authentication handled via managed identity + SDK-native two-step token exchange.

### Endpoints

- **`GET /api/write-status`** -- Performs a live blob write via the two-step token exchange and returns the result (`success-write` / `fail-write`)
- **`GET /api/health`** -- Liveness probe

### Throttling

- **Success**: 60s cooldown before next write
- **Failure**: 5s cooldown before retry
- Returns cached result with `throttled: true` and `next_write_in` seconds within the cooldown window

## Cleanup

```bash
source demo-functions-dotnet/.env

# Delete Function App resources
az group delete --name $FUNC_RESOURCE_GROUP --yes --no-wait

# Remove the blueprint (deletes all FICs with it)
# Use the Graph API to delete the application by BLUEPRINT_OBJECT_ID
```
