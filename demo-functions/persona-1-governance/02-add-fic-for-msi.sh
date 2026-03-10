#!/usr/bin/env bash
# ============================================================================
# PERSONA 1 — Central AI Governance Team
# Step 02: Add FIC for Managed Identity to Existing Blueprint
#
# Prerequisites:
#   - .env with BLUEPRINT_OBJECT_ID, TENANT_ID, MI_PRINCIPAL_ID
#   - Blueprint already created (from AKS demo)
#
# Creates:
#   - Federated Identity Credential on the blueprint for the managed identity
#
# FIC Configuration:
#   - issuer:    https://login.microsoftonline.com/{tenant}/v2.0
#   - subject:   <MI principal ID>  (NOT client ID)
#   - audiences: api://AzureADTokenExchange
#
# This is the key difference from AKS: AKS uses an external OIDC issuer
# (the K8s cluster), while Functions uses Entra itself as the issuer.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ .env file not found. Run previous steps first."
  exit 1
fi
source "$ENV_FILE"

# --- Validate required values ---
if [[ -z "${BLUEPRINT_OBJECT_ID:-}" || -z "${TENANT_ID:-}" || -z "${MI_PRINCIPAL_ID:-}" ]]; then
  echo "❌ Missing required values in .env:"
  echo "   BLUEPRINT_OBJECT_ID=${BLUEPRINT_OBJECT_ID:-<empty>}"
  echo "   TENANT_ID=${TENANT_ID:-<empty>}"
  echo "   MI_PRINCIPAL_ID=${MI_PRINCIPAL_ID:-<empty>}"
  exit 1
fi

if [[ -z "${MGMT_APP_ID:-}" || -z "${MGMT_APP_SECRET:-}" ]]; then
  echo "❌ MGMT_APP_ID and MGMT_APP_SECRET must be set in .env"
  exit 1
fi

FIC_NAME="${FIC_NAME:-msi-workload-identity}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERSONA 1: Central AI Governance Team"
echo "  Adding FIC for Managed Identity to Blueprint"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Blueprint:    $BLUEPRINT_OBJECT_ID"
echo "  MI Principal: $MI_PRINCIPAL_ID"
echo "  FIC Name:     $FIC_NAME"
echo "  Issuer:       https://login.microsoftonline.com/${TENANT_ID}/v2.0"
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

# --- Step 2: Create FIC on blueprint ---
echo ""
echo "🔗 Creating Federated Identity Credential..."

FIC_RESPONSE=$(curl -s -X POST \
  "https://graph.microsoft.com/beta/applications/${BLUEPRINT_OBJECT_ID}/federatedIdentityCredentials" \
  -H "Authorization: Bearer ${GRAPH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"${FIC_NAME}\",
    \"issuer\": \"https://login.microsoftonline.com/${TENANT_ID}/v2.0\",
    \"subject\": \"${MI_PRINCIPAL_ID}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }")

# Check for errors
if echo "$FIC_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'id' in d else 1)" 2>/dev/null; then
  FIC_ID=$(echo "$FIC_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  echo "✅ FIC created: $FIC_ID"
else
  ERROR=$(echo "$FIC_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',{}).get('message','Unknown error'))" 2>/dev/null || echo "$FIC_RESPONSE")
  echo "❌ FIC creation failed: $ERROR"
  exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ FIC added to blueprint"
echo ""
echo "  The blueprint now trusts TWO credential sources:"
echo "    1. AKS OIDC issuer (K8s service account)"
echo "    2. Managed Identity (Functions)"
echo ""
echo "  Next steps:"
echo "  1. Run 03-create-agent-id.sh (agent identity creation)"
echo "  2. Hand off .env to Persona 2"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
