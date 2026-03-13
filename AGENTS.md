# Project Context: Entra Agent ID Documentation & Testing

This project contains technical documentation, a presentation, and tooling for **Microsoft Entra Agent ID** — a purpose-built identity framework for autonomous AI agents in Microsoft Entra.

## Project Structure

- **Documentation (markdown):** Technical guides covering Agent ID on Kubernetes, Azure Functions, and governance
- **Presentation:** A PowerPoint deck (`Entra_AgentID_Workload_Identity_Federation.pptx`) built with `python-pptx`
- **Scripts:** `az-agentid-setup.sh` for Azure CLI credential isolation with a test tenant
- **Not a git repository** — this is a working project directory, not version-controlled

## Key Files

| File | Purpose |
|---|---|
| `docs/functions-agent-identity.md` | Technical reference: Agent ID on Azure Functions (two-step token exchange, C# credential classes, MSI-based federation) |
| `docs/agent-id-governance-ownership.md` | Enterprise governance: RACI, roles, lifecycle, access packages, admin consent, security guardrails |
| `docs/blog-agent-id-overview.md` | Technical blog: introduction to Agent ID for architects (blueprints, agent identities, Digital Colleagues) |
| `docs/deck.md` | Marp markdown source for the K8s portion of the presentation |
| `docs/azure-cli-tenant-isolation.md` | Azure CLI multi-tenant credential isolation guide (`AZURE_CONFIG_DIR` override) |
| `docs/demo-disable-verify.md` | Step-by-step guide to disable/re-enable agent access via FIC removal and verify from K8s |
| `az-agentid-setup.sh` | Script to isolate Azure CLI credentials for a test tenant via `AZURE_CONFIG_DIR` |
| `demo-aks/` | AKS demo app using the Microsoft Entra SDK for AgentID sidecar pattern |
| `demo-functions/` | Azure Functions demo (Python) using two-step token exchange with raw HTTP for fmi_path |
| `demo-functions-dotnet/` | Azure Functions demo (.NET 8) using SDK-native FmiTransport pattern for fmi_path |

## Demo Application Architecture

The demo uses the **Microsoft Entra SDK for AgentID** as a sidecar container — a companion auth service that handles all token management via HTTP API.

```
Pod (AKS)
├── agent-demo (Python Flask, port 8080)  — zero auth code, calls sidecar
└── entra-sdk-sidecar (port 5000)         — handles FIC, fmi_path, resource tokens
```

- Image: `mcr.microsoft.com/entra-sdk/auth-sidecar:1.0.0-azurelinux3.0-distroless`
- Sidecar docs: https://learn.microsoft.com/en-us/entra/msidweb/agent-id-sdk/overview
- App calls `/AuthorizationHeaderUnauthenticated/{service}?AgentIdentity=<id>` for tokens
- RBAC roles are assigned to the **agent identity** (not the blueprint)

## Domain Concepts

- **Agent Identity Blueprint** — Entra app registration serving as the template (class) for agents. Holds the FIC. Created by central platform team. Blueprint `id` and `appId` are the SAME GUID (unlike regular app registrations).
- **Agent Identity** — Runtime service principal (`servicePrincipalType: ServiceIdentity`) created from a blueprint. No credentials of its own. Created by dev teams. Azure RBAC recognises this SP type for role assignments.
- **Digital Colleague / Agent User** — A `microsoft.graph.agentUser` user object with own mailbox, Teams, calendar. Uses `user_fic` grant type for three-step auth.
- **Federated Identity Credential (FIC)** — Trust link configured on the blueprint (not the agent identity). On Functions: links managed identity. On K8s: links OIDC issuer.
- **Two-step token exchange (Functions)** — MSI → Blueprint exchange token (T1) → Agent Identity resource token (TR)
- **`fmi_path` parameter** — Tells Entra which child agent identity to impersonate during token exchange. Only works with `api://AzureADTokenExchange/.default` scope -- cannot request resource scopes directly.
- **Three agent modes** — Autonomous (app-only), Interactive (OBO), Digital Colleague (own user identity)
- **Microsoft Entra SDK for AgentID** — Containerised sidecar (`mcr.microsoft.com/entra-sdk/auth-sidecar`) that handles all token management via HTTP API. Handles FIC exchange, fmi_path, and resource token acquisition transparently. Recommended for polyglot microservices on K8s.

## Style & Conventions

- Use `--` for em-dashes in markdown content (not `—`)
- Technical writing: direct, precise, no marketing language
- Never reference specific users, authors, or personal identities in code comments, commit messages, or documentation
- Code examples use C#, Python, PowerShell, and raw HTTP requests
- ASCII diagrams for architecture (no image dependencies)
- When modifying the PowerPoint, use `python-pptx` via a temporary Python script (delete after execution)
- Azure CLI commands use `az` with `--query` and `-o table` for readable output

## Azure Context

- The project may use an isolated Azure CLI session (`AZURE_CONFIG_DIR=~/.azure-agentid-test`) for a test tenant
- All Microsoft Graph API calls use the `/beta` endpoint (Agent ID is in preview)
- Key Graph API types: `Microsoft.Graph.AgentIdentityBlueprint`, `Microsoft.Graph.AgentIdentity`, `microsoft.graph.agentUser`
- Key Graph endpoints: `/beta/applications/`, `/beta/serviceprincipals/Microsoft.Graph.AgentIdentity`, `/beta/serviceprincipals/graph.agentIdentityBlueprintPrincipal`

## Reference Implementation

- [astaykov/entra-agent-id-preview-guide](https://github.com/astaykov/entra-agent-id-preview-guide) — Hands-on REST API + PowerShell + Insomnia collection
- [Christian Posta — Entra Agent ID on Kubernetes](https://blog.christianposta.com/entra-agent-id-agw/) — Multi-part K8s series with workload identity federation
- [Microsoft Entra Agent ID Docs](https://learn.microsoft.com/entra/agent-id/)
- [Microsoft Entra SDK for AgentID](https://learn.microsoft.com/en-us/entra/msidweb/agent-id-sdk/overview) — Official sidecar SDK docs (installation, configuration, endpoints, scenarios)
- [Entra SDK Python Integration](https://learn.microsoft.com/en-us/entra/msidweb/agent-id-sdk/scenarios/using-from-python) — Flask/FastAPI/Django integration patterns
