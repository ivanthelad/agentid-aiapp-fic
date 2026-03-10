# Demo: Disabling and Verifying Agent Identity Access

This guide walks through disabling agent identity access at the blueprint level and verifying the effect from inside the AKS cluster. This is the key governance demo -- showing that central teams can cut off agent access instantly by removing the Federated Identity Credential (FIC) from the blueprint.

## How It Works

The agent identity has **no credentials of its own**. It relies entirely on the blueprint's FIC to authenticate. The chain is:

```
K8s Service Account JWT
    → Blueprint FIC (trust link)
        → Entra SDK Sidecar (token exchange)
            → Agent Identity token (fmi_path)
                → Resource token (e.g., Azure Storage)
```

Removing the FIC breaks the first link. The K8s JWT is no longer trusted, so no tokens can be acquired -- the agent identity is effectively disabled.

## Prerequisites

- Azure CLI logged in to the test tenant:
  ```bash
  export AZURE_CONFIG_DIR=~/.azure-agentid-test
  ```
- `kubectl` configured for the AKS cluster
- The demo app deployed and working (blob writes succeeding)
- The `.env` file populated from the demo setup

## Step 1: Verify Current State (Working)

First, confirm the agent identity is currently operational:

```bash
source demo-aks/.env

# Port-forward to the demo pod
POD=$(kubectl get pods -n agent-demo -l app=agent-demo -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward pod/$POD 8080:8080 -n agent-demo &

# Check blob write status -- should show "success-write"
curl -s http://localhost:8080/write-status | python3 -m json.tool
```

Expected: `last_result: "success-write"` confirming the agent identity can access Azure Storage.

## Step 2: List the FIC on the Blueprint

Identify the FIC to disable:

```bash
source demo-aks/.env

az rest --method GET \
  --url "https://graph.microsoft.com/beta/applications/${BLUEPRINT_OBJECT_ID}/federatedIdentityCredentials" \
  --headers "Content-Type=application/json" | python3 -m json.tool
```

Note the FIC `id` (e.g., `01b0c85e-771d-49ee-ba80-dd7464c96d58`) and `name` (e.g., `aks-workload-identity`).

## Step 3: Delete the FIC (Disable Access)

Remove the FIC from the blueprint. This is the governance action -- the central AI team revokes the trust link:

```bash
source demo-aks/.env

FIC_ID="<fic-id-from-step-2>"

az rest --method DELETE \
  --url "https://graph.microsoft.com/beta/applications/${BLUEPRINT_OBJECT_ID}/federatedIdentityCredentials/${FIC_ID}" \
  --headers "Content-Type=application/json"
```

**Alternative -- Entra Portal UI:**
1. Go to [Entra Admin Center](https://entra.microsoft.com)
2. Navigate to **Applications** > **App registrations** > search for your blueprint name
3. Select **Certificates & secrets** > **Federated credentials**
4. Delete the `aks-workload-identity` credential

## Step 4: Wait for Token Expiry

The sidecar caches tokens. Existing cached tokens remain valid until they expire. Agent identity tokens have a **60-minute TTL** (standard Entra ID access token lifetime). Options:

- **Option A: Wait up to 60 minutes** -- tokens expire naturally, then the next sidecar token acquisition fails
- **Option B: Restart the pod** (recommended for demos) -- forces the sidecar to discard cached tokens and re-acquire immediately, which fails because the FIC is gone:
  ```bash
  kubectl rollout restart deployment/agent-demo -n agent-demo
  kubectl rollout status deployment/agent-demo -n agent-demo --timeout=120s
  ```

## Step 5: Verify Access Is Revoked

After the pod restarts (or tokens expire), check the endpoints:

```bash
POD=$(kubectl get pods -n agent-demo -l app=agent-demo -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward pod/$POD 8080:8080 -n agent-demo &
sleep 3

# Check blob write status -- should now show "fail-write"
curl -s http://localhost:8080/write-status | python3 -m json.tool
```

Expected:
- `last_result: "fail-write"` -- blob writes fail because no storage token can be acquired
- Error messages referencing AADSTS700016 or "no matching federated identity record found"

You can also check the pod logs:

```bash
kubectl logs $POD -n agent-demo -c agent-demo | tail -5
kubectl logs $POD -n agent-demo -c entra-sdk-sidecar | tail -10
```

## Step 6: Re-enable Access

Restore the FIC to bring the agent identity back online:

```bash
source demo-aks/.env

# Re-create the FIC with the same parameters
az rest --method POST \
  --url "https://graph.microsoft.com/beta/applications/${BLUEPRINT_OBJECT_ID}/federatedIdentityCredentials" \
  --headers "Content-Type=application/json" \
  --body '{
    "name": "aks-workload-identity",
    "issuer": "'"${OIDC_ISSUER_URL}"'",
    "subject": "system:serviceaccount:'"${K8S_NAMESPACE}"':'"${K8S_SA_NAME}"'",
    "audiences": ["api://AzureADTokenExchange"],
    "description": "AKS workload identity for agent demo"
  }'
```

Then restart the pod to pick up the restored FIC:

```bash
kubectl rollout restart deployment/agent-demo -n agent-demo
kubectl rollout status deployment/agent-demo -n agent-demo --timeout=120s
```

## Step 7: Verify Recovery

```bash
POD=$(kubectl get pods -n agent-demo -l app=agent-demo -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward pod/$POD 8080:8080 -n agent-demo &
sleep 3

# Should be back to "success-write"
curl -s http://localhost:8080/write-status | python3 -m json.tool
```

## Quick Reference Commands

| Action | Command |
|---|---|
| Check write status | `curl -s http://localhost:8080/write-status \| python3 -m json.tool` |
| Check sidecar health | `curl -s http://localhost:8080/sidecar-health` |
| View app logs | `kubectl logs $POD -n agent-demo -c agent-demo --tail=10` |
| View sidecar logs | `kubectl logs $POD -n agent-demo -c entra-sdk-sidecar --tail=10` |
| Force token refresh | `kubectl rollout restart deployment/agent-demo -n agent-demo` |
| List FICs | `az rest --method GET --url "https://graph.microsoft.com/beta/applications/${BLUEPRINT_OBJECT_ID}/federatedIdentityCredentials"` |

## What This Demonstrates

1. **Centralised governance** -- the platform team controls the FIC on the blueprint. Deleting it instantly (after cache expiry) disables all agent identities created from that blueprint.
2. **No code changes required** -- the agent app and its deployment are untouched. Access is controlled entirely at the identity layer.
3. **Granular control** -- you can disable a single blueprint's K8s trust without affecting other blueprints or other FIC types (e.g., managed identity FICs remain active).
4. **Recoverable** -- re-creating the FIC with identical parameters restores access. No data loss, no redeployment.
5. **Agent identity has no independent credentials** -- this is by design. The agent cannot circumvent governance by creating its own credentials.
