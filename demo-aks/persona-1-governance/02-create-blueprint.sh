#!/usr/bin/env bash
# ============================================================================
# PERSONA 1 — Central AI Governance Team
# Step 02: Create Agent Identity Blueprint + FIC
#
# Prerequisites:
#   - Logged in to test tenant: source ../az-agentid-setup.sh
#   - Agent ID Administrator role assigned
#   - OIDC issuer URL (from 01-provision-aks.sh or set manually)
#
# Creates:
#   - Agent Identity Blueprint (app registration)
#   - Blueprint Service Principal
#   - Federated Identity Credential (linked to AKS OIDC issuer)
#
# Outputs:
#   - Appends config values to ../.env
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# Source .env if it exists (for OIDC_ISSUER_URL, TENANT_ID, etc.)
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

# --- Configuration ---
BLUEPRINT_NAME="${BLUEPRINT_NAME:-agentid-demo-blueprint}"
SPONSOR_GROUP_ID="${SPONSOR_GROUP_ID:-}"
K8S_NAMESPACE="${K8S_NAMESPACE:-agent-demo}"
K8S_SA_NAME="${K8S_SA_NAME:-agent-sa}"

# Ensure we have required values
TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"

if [[ -z "${OIDC_ISSUER_URL:-}" ]]; then
  echo "⚠️  OIDC_ISSUER_URL not set. Run 01-provision-aks.sh first, or set it manually in .env"
  echo "   Example: OIDC_ISSUER_URL=https://eastus.oic.prod-aks.azure.com/..."
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERSONA 1: Central AI Governance Team"
echo "  Creating Agent Identity Blueprint"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Tenant:     $TENANT_ID"
echo "  Blueprint:  $BLUEPRINT_NAME"
echo "  OIDC:       $OIDC_ISSUER_URL"
echo "  K8s SA:     system:serviceaccount:${K8S_NAMESPACE}:${K8S_SA_NAME}"
echo ""

# --- Step 1: Get access token for Graph API (app-only, client_credentials) ---
echo "🔑 Acquiring Graph API token via client credentials..."

if [[ -z "${MGMT_APP_ID:-}" || -z "${MGMT_APP_SECRET:-}" ]]; then
  echo ""
  echo "⚠️  MGMT_APP_ID and MGMT_APP_SECRET not found in .env"
  echo ""
  echo "  A management app registration is required for Agent ID API calls."
  echo "  It needs: Application.ReadWrite.All (application) + Agent ID Administrator role"
  echo ""
  read -rp "  Enter MGMT_APP_ID (client ID): " MGMT_APP_ID
  read -rp "  Enter MGMT_APP_SECRET (client secret): " MGMT_APP_SECRET
  echo ""

  if [[ -z "$MGMT_APP_ID" || -z "$MGMT_APP_SECRET" ]]; then
    echo "❌ Both MGMT_APP_ID and MGMT_APP_SECRET are required."
    exit 1
  fi

  # Prompt for sponsor group (required by Agent ID APIs)
  if [[ -z "${SPONSOR_GROUP_ID:-}" ]]; then
    read -rp "  Enter SPONSOR_GROUP_ID (security group, required): " SPONSOR_GROUP_ID
    echo ""
  fi

  # Save to .env for subsequent scripts
  cat >> "$ENV_FILE" << EOF

# --- Management App (added by 02-create-blueprint.sh) ---
MGMT_APP_ID=${MGMT_APP_ID}
MGMT_APP_SECRET=${MGMT_APP_SECRET}
SPONSOR_GROUP_ID=${SPONSOR_GROUP_ID:-}
EOF
  echo "  💾 Saved to .env"
  echo ""
fi

TOKEN_RESPONSE=$(curl -s -X POST \
  "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  --data-urlencode "client_id=${MGMT_APP_ID}" \
  --data-urlencode "client_secret=${MGMT_APP_SECRET}" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" \
  --data-urlencode "grant_type=client_credentials")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
  echo "❌ Failed to acquire token:"
  echo "$TOKEN_RESPONSE" | jq '.error_description // .'
  exit 1
fi

# --- Step 2: Create Agent Identity Blueprint ---
echo "📋 Creating Agent Identity Blueprint..."

if [[ -n "$SPONSOR_GROUP_ID" ]]; then
  BLUEPRINT_BODY=$(jq -n \
    --arg name "$BLUEPRINT_NAME" \
    --arg sponsor "https://graph.microsoft.com/v1.0/groups/${SPONSOR_GROUP_ID}" \
    '{
      "@odata.type": "Microsoft.Graph.AgentIdentityBlueprint",
      "displayName": $name,
      "sponsors@odata.bind": [$sponsor]
    }')
else
  echo "⚠️  SPONSOR_GROUP_ID not set — creating blueprint without sponsor."
  BLUEPRINT_BODY=$(jq -n \
    --arg name "$BLUEPRINT_NAME" \
    '{
      "@odata.type": "Microsoft.Graph.AgentIdentityBlueprint",
      "displayName": $name
    }')
fi

BLUEPRINT_RESPONSE=$(curl -s -X POST \
  "https://graph.microsoft.com/beta/applications/" \
  -H "Content-Type: application/json" \
  -H "OData-Version: 4.0" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "$BLUEPRINT_BODY")

# Check for errors
if echo "$BLUEPRINT_RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
  echo "❌ Failed to create blueprint:"
  echo "$BLUEPRINT_RESPONSE" | jq '.error'
  exit 1
fi

BLUEPRINT_OBJECT_ID=$(echo "$BLUEPRINT_RESPONSE" | jq -r '.id')
BLUEPRINT_APP_ID=$(echo "$BLUEPRINT_RESPONSE" | jq -r '.appId')

echo "✅ Blueprint created"
echo "   Object ID: $BLUEPRINT_OBJECT_ID"
echo "   App ID:    $BLUEPRINT_APP_ID"

# Wait for replication before creating SP
echo ""
echo "⏳ Waiting 30 seconds for replication..."
sleep 30

# --- Step 3: Create Blueprint Service Principal ---
echo ""
echo "📋 Creating Blueprint Service Principal..."

SP_RESPONSE=$(curl -s -X POST \
  "https://graph.microsoft.com/beta/serviceprincipals/graph.agentIdentityBlueprintPrincipal" \
  -H "Content-Type: application/json" \
  -H "OData-Version: 4.0" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "$(jq -n --arg appId "$BLUEPRINT_APP_ID" '{"appId": $appId}')")

if echo "$SP_RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
  echo "❌ Failed to create service principal:"
  echo "$SP_RESPONSE" | jq '.error'
  exit 1
fi

BLUEPRINT_SP_ID=$(echo "$SP_RESPONSE" | jq -r '.id')
echo "✅ Blueprint Service Principal created"
echo "   SP Object ID: $BLUEPRINT_SP_ID"

# Wait for replication before creating FIC
echo ""
echo "⏳ Waiting 20 seconds for SP replication..."
sleep 20

# --- Step 4: Add Federated Identity Credential ---
echo "🔗 Adding Federated Identity Credential (K8s OIDC)..."

FIC_BODY=$(jq -n \
  --arg name "aks-workload-identity" \
  --arg issuer "$OIDC_ISSUER_URL" \
  --arg subject "system:serviceaccount:${K8S_NAMESPACE}:${K8S_SA_NAME}" \
  '{
    name: $name,
    issuer: $issuer,
    subject: $subject,
    audiences: ["api://AzureADTokenExchange"],
    description: "AKS workload identity for agent demo"
  }')

FIC_RESPONSE=$(curl -s -X POST \
  "https://graph.microsoft.com/beta/applications/${BLUEPRINT_OBJECT_ID}/federatedIdentityCredentials" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "$FIC_BODY")

if echo "$FIC_RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
  echo "❌ Failed to create FIC:"
  echo "$FIC_RESPONSE" | jq '.error'
  exit 1
fi

echo "✅ FIC created"
echo "   Issuer:  $OIDC_ISSUER_URL"
echo "   Subject: system:serviceaccount:${K8S_NAMESPACE}:${K8S_SA_NAME}"

# --- Step 5: Update Service Account with blueprint app ID ---
echo ""
echo "📋 Updating Service Account annotation with blueprint app ID..."

kubectl annotate serviceaccount "${K8S_SA_NAME}" \
  -n "${K8S_NAMESPACE}" \
  "azure.workload.identity/client-id=${BLUEPRINT_APP_ID}" \
  --overwrite 2>/dev/null && \
  echo "✅ Service Account updated" || \
  echo "⚠️  Could not update SA — run kubectl annotate manually after getting cluster credentials"

# --- Step 6: Write config to .env ---
echo ""
echo "💾 Writing config to $ENV_FILE..."

cat >> "$ENV_FILE" << EOF

# --- Blueprint config (Persona 1 output) ---
TENANT_ID=${TENANT_ID}
BLUEPRINT_OBJECT_ID=${BLUEPRINT_OBJECT_ID}
BLUEPRINT_APP_ID=${BLUEPRINT_APP_ID}
BLUEPRINT_SP_ID=${BLUEPRINT_SP_ID}
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Blueprint setup complete"
echo ""
echo "  Next steps:"
echo "  1. Hand off .env to the Agent Dev Team (Persona 2)"
echo "  2. Run 03-create-agent-id.sh (agent identity creation)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
