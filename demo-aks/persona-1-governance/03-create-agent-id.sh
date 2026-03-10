#!/usr/bin/env bash
# ============================================================================
# PERSONA 1 — Central AI Governance Team
# Step 03: Create Agent Identity
#
# Prerequisites:
#   - .env populated by previous steps (01-provision-aks.sh + 02-create-blueprint.sh)
#   - Logged in to test tenant: source ../az-agentid-setup.sh
#
# Creates:
#   - Agent Identity (service principal linked to blueprint)
#
# Note: Agent identity creation is a central governance responsibility.
# Agent identities are tenant-level Entra security primitives -- central
# ownership ensures least-privilege, auditable token issuance, and prevents
# uncontrolled identity minting from spoke landing zones.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ .env file not found. Run Persona 1 scripts first."
  exit 1
fi
source "$ENV_FILE"

# --- Configuration ---
AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME:-agentid-demo-agent-01}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERSONA 1: Central AI Governance Team"
echo "  Creating Agent Identity"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Blueprint App ID: $BLUEPRINT_APP_ID"
echo "  Agent Name:       $AGENT_DISPLAY_NAME"
echo ""

# --- Step 1: Get access token via client credentials ---
echo "🔑 Acquiring Graph API token via client credentials..."

if [[ -z "${MGMT_APP_ID:-}" || -z "${MGMT_APP_SECRET:-}" ]]; then
  echo "❌ MGMT_APP_ID and MGMT_APP_SECRET must be set in .env"
  echo "   These should have been written by 02-create-blueprint.sh."
  echo "   If running manually, add them to .env before this step."
  exit 1
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

# --- Step 2: Create Agent Identity ---
echo "📋 Creating Agent Identity..."

if [[ -n "${SPONSOR_GROUP_ID:-}" ]]; then
  AGENT_BODY=$(jq -n \
    --arg name "$AGENT_DISPLAY_NAME" \
    --arg appId "$BLUEPRINT_APP_ID" \
    --arg sponsor "https://graph.microsoft.com/v1.0/groups/${SPONSOR_GROUP_ID}" \
    '{
      "displayName": $name,
      "agentAppId": $appId,
      "sponsors@odata.bind": [$sponsor]
    }')
else
  echo "⚠️  SPONSOR_GROUP_ID not set — agent identity creation may fail."
  AGENT_BODY=$(jq -n \
    --arg name "$AGENT_DISPLAY_NAME" \
    --arg appId "$BLUEPRINT_APP_ID" \
    '{
      "displayName": $name,
      "agentAppId": $appId
    }')
fi

AGENT_RESPONSE=$(curl -s -X POST \
  "https://graph.microsoft.com/beta/serviceprincipals/Microsoft.Graph.AgentIdentity" \
  -H "Content-Type: application/json" \
  -H "OData-Version: 4.0" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "$AGENT_BODY")

if echo "$AGENT_RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
  echo "❌ Failed to create agent identity:"
  echo "$AGENT_RESPONSE" | jq '.error'
  exit 1
fi

AGENT_IDENTITY_ID=$(echo "$AGENT_RESPONSE" | jq -r '.appId // .id')
AGENT_IDENTITY_OBJECT_ID=$(echo "$AGENT_RESPONSE" | jq -r '.id')

echo "✅ Agent Identity created"
echo "   Client ID:  $AGENT_IDENTITY_ID"
echo "   Object ID:  $AGENT_IDENTITY_OBJECT_ID"

# --- Step 3: Append to .env ---
echo ""
echo "💾 Updating $ENV_FILE..."

cat >> "$ENV_FILE" << EOF

# --- Agent Identity config (Persona 2 output) ---
AGENT_IDENTITY_ID=${AGENT_IDENTITY_ID}
AGENT_IDENTITY_OBJECT_ID=${AGENT_IDENTITY_OBJECT_ID}
AGENT_DISPLAY_NAME=${AGENT_DISPLAY_NAME}
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Agent Identity created"
echo ""
echo "  Next steps:"
echo "  1. Hand off .env to Persona 2 (Agent Dev Team)"
echo "  2. Persona 2 runs 04-setup-resources.sh to create ACR, storage, and RBAC"
echo "  3. Persona 2 runs 05-deploy-app.sh to deploy the demo app"
echo "  4. Persona 2 runs 06-verify.sh to test token retrieval"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
