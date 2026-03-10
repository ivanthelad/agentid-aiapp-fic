#!/usr/bin/env bash
# ============================================================================
# PERSONA 1 — Central AI Governance Team
# Step 03: Create Agent Identity from Blueprint
#
# Prerequisites:
#   - .env with BLUEPRINT_APP_ID, MGMT_APP_ID, MGMT_APP_SECRET, SPONSOR_GROUP_ID
#
# Creates:
#   - Agent Identity service principal (linked to blueprint via agentAppId)
#
# Agent identity creation is a central governance responsibility.
# Agent identities are tenant-level Entra security primitives -- central
# ownership ensures least-privilege, auditable token issuance, and prevents
# uncontrolled identity minting from spoke landing zones.
#
# The agent identity is a ServiceIdentity SP -- it has no credentials of its
# own. RBAC roles for resource access are assigned to THIS identity.
#
# Outputs:
#   - Appends AGENT_IDENTITY_ID, AGENT_IDENTITY_OBJECT_ID to ../.env
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ .env file not found. Run previous steps first."
  exit 1
fi
source "$ENV_FILE"

# --- Validate ---
if [[ -z "${BLUEPRINT_APP_ID:-}" ]]; then
  echo "❌ BLUEPRINT_APP_ID not set in .env"
  exit 1
fi
if [[ -z "${MGMT_APP_ID:-}" || -z "${MGMT_APP_SECRET:-}" ]]; then
  echo "❌ MGMT_APP_ID and MGMT_APP_SECRET must be set in .env"
  exit 1
fi

AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME:-agentid-func-dotnet-agent-01}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERSONA 1: Central AI Governance Team"
echo "  Creating Agent Identity (Functions)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Blueprint:  $BLUEPRINT_APP_ID"
echo "  Agent Name: $AGENT_DISPLAY_NAME"
echo ""

# --- Step 1: Get Graph API token ---
echo "🔑 Acquiring Graph API token..."
GRAPH_TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  --data-urlencode "client_id=${MGMT_APP_ID}" \
  --data-urlencode "client_secret=${MGMT_APP_SECRET}" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" \
  --data-urlencode "grant_type=client_credentials" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "✅ Token acquired"

# --- Step 2: Create Agent Identity ---
echo ""
echo "🤖 Creating Agent Identity..."

AGENT_RESPONSE=$(curl -s -X POST \
  "https://graph.microsoft.com/beta/serviceprincipals/Microsoft.Graph.AgentIdentity" \
  -H "Authorization: Bearer ${GRAPH_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "OData-Version: 4.0" \
  -d "{
    \"displayName\": \"${AGENT_DISPLAY_NAME}\",
    \"agentAppId\": \"${BLUEPRINT_APP_ID}\",
    \"sponsors@odata.bind\": [
      \"https://graph.microsoft.com/v1.0/groups/${SPONSOR_GROUP_ID}\"
    ]
  }")

if echo "$AGENT_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'id' in d else 1)" 2>/dev/null; then
  AGENT_IDENTITY_ID=$(echo "$AGENT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['appId'])")
  AGENT_IDENTITY_OBJECT_ID=$(echo "$AGENT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  echo "✅ Agent Identity created"
  echo "   App ID:    $AGENT_IDENTITY_ID"
  echo "   Object ID: $AGENT_IDENTITY_OBJECT_ID"
else
  ERROR=$(echo "$AGENT_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',{}).get('message','Unknown error'))" 2>/dev/null || echo "$AGENT_RESPONSE")
  echo "❌ Agent Identity creation failed: $ERROR"
  exit 1
fi

# --- Step 3: Wait for replication ---
echo ""
echo "⏳ Waiting 20s for Entra replication..."
sleep 20

# --- Step 4: Append to .env ---
echo "💾 Updating $ENV_FILE..."

cat >> "$ENV_FILE" << EOF

# --- Agent Identity config (Persona 2 — Step 03 output) ---
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
echo "  2. Persona 2 runs 04-setup-storage.sh (storage + RBAC on agent identity)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
