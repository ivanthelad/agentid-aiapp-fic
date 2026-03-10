# Azure CLI -- Multi-Tenant Credential Isolation

## The Core Override

```bash
export AZURE_CONFIG_DIR=~/.azure-agentid-test
```

This single environment variable is the foundation of everything below. Azure CLI reads **all** session state -- tokens, subscriptions, profile, settings -- from the directory specified by `AZURE_CONFIG_DIR`. When unset, it defaults to `~/.azure`. By pointing it to a different path, you get a completely independent Azure CLI session with its own login, its own subscriptions, and its own token cache. Your default credentials are never touched.

---

## Prerequisites

- Azure CLI 2.x installed (`az --version`)
- Access to a secondary Azure tenant for testing
- The test tenant must be onboarded to the Entra Agent ID preview

---

## 1. How It Works

Azure CLI stores all session state (tokens, subscriptions, profile) in `~/.azure` by default. Setting `AZURE_CONFIG_DIR` to a different path gives you a parallel, isolated session.

### Setup Script

A convenience script is provided at `az-agentid-setup.sh`. It must be **sourced** (not executed) so the environment variable persists in your current shell.

#### First-time setup

```bash
source ./az-agentid-setup.sh
```

This will:

1. Create `~/.azure-agentid-test` as an isolated config directory
2. Set `AZURE_CONFIG_DIR` to point to it
3. Add an `az-test` alias to your shell profile (`.zshrc` or `.bashrc`)
4. Prompt you for your test tenant ID and open a browser for login

After sourcing, all `az` commands in that shell session target the test tenant.

#### Return to default credentials

```bash
source ./az-agentid-setup.sh --reset
```

This unsets `AZURE_CONFIG_DIR`, restoring your normal `~/.azure` credentials.

#### Using the alias from any shell

Once the alias is installed, you can use `az-test` from any terminal without sourcing the script:

```bash
az-test account show                     # check test tenant context
az-test login --tenant <TENANT_ID>       # login to test tenant
az-test group list                       # list resource groups in test tenant
```

Your default `az` commands remain unaffected.

---

## 2. How It Works

| Component | Default | Isolated (test) |
|---|---|---|
| Config directory | `~/.azure` | `~/.azure-agentid-test` |
| Token cache | `~/.azure/msal_token_cache.json` | `~/.azure-agentid-test/msal_token_cache.json` |
| Subscription profile | `~/.azure/azureProfile.json` | `~/.azure-agentid-test/azureProfile.json` |
| Environment variable | `AZURE_CONFIG_DIR` not set | `AZURE_CONFIG_DIR=~/.azure-agentid-test` |

The two sessions are completely independent. Logging in, switching subscriptions, or modifying settings in one has zero effect on the other.

---

## 3. Verifying the Setup

```bash
# Terminal 1 — default credentials
az account show --query '{tenant:tenantId, subscription:name}' -o table

# Terminal 2 — test credentials
export AZURE_CONFIG_DIR=~/.azure-agentid-test
az account show --query '{tenant:tenantId, subscription:name}' -o table
```

These should show different tenants.

---

## 4. Copilot CLI Integration

When working with Copilot CLI in this project, set the environment variable before starting:

```bash
export AZURE_CONFIG_DIR=~/.azure-agentid-test
copilot
```

All `az` commands executed by Copilot during that session will use the test tenant credentials.

---

## 5. Cleanup

To remove the isolated environment entirely:

```bash
rm -rf ~/.azure-agentid-test
```

Remove the alias from your shell profile by deleting the `az-test` lines from `~/.zshrc` or `~/.bashrc`.
