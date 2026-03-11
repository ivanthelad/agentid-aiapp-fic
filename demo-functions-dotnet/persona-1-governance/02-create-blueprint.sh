#!/usr/bin/env bash
# ============================================================================
# PERSONA 1 — Central AI Governance Team
# Step 02: Create Agent Identity Blueprint + MSI FIC
#
# Prerequisites:
#   - Logged in to test tenant: source ../az-agentid-setup.sh
#   - .env with MGMT_APP_ID, MGMT_APP_SECRET, SPONSOR_GROUP_ID
#     (from 00-setup-prerequisites.sh)
#   - .env with MI_PRINCIPAL_ID (from 01-provision-function.sh)
#
# Creates:
#   - Agent Identity Blueprint (app registration)
#   - Blueprint Service Principal
#   - Federated Identity Credential (linked to managed identity)
#
# FIC Configuration (MSI-based, different from AKS OIDC):
#   - issuer:    https://login.microsoftonline.com/{tenant}/v2.0
#   - subject:   <MI principal ID>  (NOT client ID)
#   - audiences: api://AzureADTokenExchange
#
# Outputs:
#   - Appends TENANT_ID, BLUEPRINT_OBJECT_ID, BLUEPRINT_APP_ID,
#     BLUEPRINT_SP_ID to ../.env
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ .env file not found. Run 00-setup-prerequisites.sh and 01-provision-function.sh first."
  exit 1
fi
source "$ENV_FILE"

# --- Configuration ---
BLUEPRINT_NAME="${BLUEPRINT_NAME:-agentid-func-dotnet-blueprint}"
FIC_NAME="${FIC_NAME:-msi-workload-identity}"
TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"

# --- Validate required values ---
if [[ -z "${MGMT_APP_ID:-}" || -z "${MGMT_APP_SECRET:-}" ]]; then
  echo "❌ MGMT_APP_ID and MGMT_APP_SECRET must be set in .env"
  echo "   Run 00-setup-prerequisites.sh first."
  exit 1
fi

if [[ -z "${SPONSOR_GROUP_ID:-}" ]]; then
  echo "❌ SPONSOR_GROUP_ID must be set in .env"
  echo "   Run 00-setup-prerequisites.sh first."
  exit 1
fi

if [[ -z "${MI_PRINCIPAL_ID:-}" ]]; then
  echo "❌ MI_PRINCIPAL_ID must be set in .env"
  echo "   Run 01-provision-function.sh first."
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERSONA 1: Central AI Governance Team"
echo "  Creating Agent Identity Blueprint + MSI FIC"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Tenant:       $TENANT_ID"
echo "  Blueprint:    $BLUEPRINT_NAME"
echo "  MI Principal: $MI_PRINCIPAL_ID"
echo "  FIC Name:     $FIC_NAME"
echo "  Issuer:       https://login.microsoftonline.com/${TENANT_ID}/v2.0"
echo ""

# --- Step 1: Get access token for Graph API (app-only, client_credentials) ---
echo "🔑 Acquiring Graph API token via client credentials..."

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

BLUEPRINT_BODY=$(jq -n \
  --arg name "$BLUEPRINT_NAME" \
  --arg sponsor "https://graph.microsoft.com/v1.0/groups/${SPONSOR_GROUP_ID}" \
  '{
    "@odata.type": "Microsoft.Graph.AgentIdentityBlueprint",
    "displayName": $name,
    "sponsors@odata.bind": [$sponsor]
  }')

BLUEPRINT_RESPONSE=$(curl -s -X POST \
  "https://graph.microsoft.com/beta/applications/" \
  -H "Content-Type: application/json" \
  -H "OData-Version: 4.0" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "$BLUEPRINT_BODY")

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

# --- Step 4: Add Federated Identity Credential (MSI-based) ---
echo "🔗 Adding Federated Identity Credential (Managed Identity)..."

FIC_BODY=$(jq -n \
  --arg name "$FIC_NAME" \
  --arg issuer "https://login.microsoftonline.com/${TENANT_ID}/v2.0" \
  --arg subject "$MI_PRINCIPAL_ID" \
  '{
    name: $name,
    issuer: $issuer,
    subject: $subject,
    audiences: ["api://AzureADTokenExchange"],
    description: "Managed identity federation for .NET Functions agent demo"
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
echo "   Issuer:  https://login.microsoftonline.com/${TENANT_ID}/v2.0"
echo "   Subject: $MI_PRINCIPAL_ID"

# --- Step 5: Write config to .env ---
echo ""
echo "💾 Writing config to $ENV_FILE..."

cat >> "$ENV_FILE" << EOF

# --- Blueprint config (created by 02-create-blueprint.sh) ---
TENANT_ID=${TENANT_ID}
BLUEPRINT_OBJECT_ID=${BLUEPRINT_OBJECT_ID}
BLUEPRINT_APP_ID=${BLUEPRINT_APP_ID}
BLUEPRINT_SP_ID=${BLUEPRINT_SP_ID}
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Blueprint + FIC setup complete"
echo ""
echo "  Blueprint trusts the managed identity via FIC."
echo "  This is Entra-to-Entra federation (MSI → Blueprint)."
echo ""
echo "  Next steps:"
echo "  1. Run 03-create-agent-id.sh (agent identity creation)"
echo "  2. Hand off .env to Persona 2"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
