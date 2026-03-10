# Copilot Instructions

## Project Overview

This project contains documentation, a presentation, and a demo application for Microsoft Entra Agent ID — a purpose-built identity framework for autonomous AI agents.

## Git Workflow

- You may commit changes, but **do not push** without explicit user consent.

## Key Conventions

- Use `--` for em-dashes in markdown (not `—`)
- All Microsoft Graph API calls use the `/beta` endpoint (Agent ID is in preview)
- Azure CLI commands use `az rest` for Graph API calls and `az` for Azure resource management
- Scripts use bash, not PowerShell
- The project uses an isolated Azure CLI session for a test tenant (`AZURE_CONFIG_DIR=~/.azure-agentid-test`)

## Agent ID Skill

When working with Agent ID concepts, blueprints, agent identities, token exchange, or governance patterns, use the `/agent-id` skill. This skill contains accumulated knowledge about API patterns, field names, token flows, persona separation, and common gotchas.

**Always update the skill** (`.github/skills/agent-id/SKILL.md`) when you discover new information about Agent ID — API changes, error resolutions, behavioral quirks, or corrections to existing documentation.

## Project Structure

- `docs/` — Technical documentation (functions guide, governance guide, blog post)
- `demo-aks/` — Demo application with persona-separated scripts and a Python AKS app
- `AGENTS.md` — Project context for AI agents (domain concepts, file purposes)
- `.github/skills/agent-id/` — Agent ID knowledge skill

## Demo Application

The demo in `demo-aks/` uses the **Microsoft Entra SDK for AgentID** sidecar pattern:
- `demo-aks/app/` — Python Flask app with zero auth code (calls sidecar via HTTP)
- `demo-aks/persona-1-governance/` — Central AI governance team scripts (blueprint creation, AKS provisioning, agent identity creation)
- `demo-aks/persona-2-developer/` — Agent dev team scripts (app deployment with sidecar, verification)

The sidecar container (`mcr.microsoft.com/entra-sdk/auth-sidecar:1.0.0-azurelinux3.0-distroless`) runs in the same pod and handles all token management. The app calls `http://localhost:5000/AuthorizationHeaderUnauthenticated/{service}?AgentIdentity=<id>` to get tokens.

Scripts read config from `demo-aks/.env`. The `.env` file is populated by Persona 1 scripts (including agent identity creation) and consumed by Persona 2 scripts, simulating the handoff between teams.

### Key Sidecar Config Notes
- Scopes use indexed format: `DownstreamApis__Storage__Scopes__0` (not `Scopes`)
- Use TCP socket probes for the sidecar (HTTP probes on `/healthz` return 400)
- Set `ASPNETCORE_URLS=http://+:5000` explicitly
- RBAC roles go on the **agent identity**, not the blueprint
