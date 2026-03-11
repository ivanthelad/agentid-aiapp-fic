#!/usr/bin/env bash
# ============================================================================
# PERSONA 1 — Central AI Governance Team
# Step 00: One-Time Prerequisites Setup
#
# Creates the foundational resources needed before any Agent ID operations:
#   1. Sponsor security group (required by Agent ID APIs)
#   2. Management app registration (for Graph API client_credentials calls)
#      - Application.ReadWrite.All (application permission)
#      - Agent ID Administrator directory role
#      - Client secret
#
# Prerequisites:
#   - Logged in to test tenant: source ../az-agentid-setup.sh
#   - Current user must be Global Admin or Privileged Role Admin
#     (to consent permissions and assign directory roles)
#
# This script only needs to run ONCE per tenant. The management app and
# sponsor group are reused across all blueprints and agent identities.
#
# Outputs:
#   - Writes MGMT_APP_ID, MGMT_APP_SECRET, SPONSOR_GROUP_ID to ../.env
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# Source .env if it exists (to avoid recreating if already set)
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

# --- Configuration ---
MGMT_APP_NAME="${MGMT_APP_NAME:-agentid-mgmt-app}"
SPONSOR_GROUP_NAME="${SPONSOR_GROUP_NAME:-agentid-sponsors}"
TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERSONA 1: Central AI Governance Team"
echo "  One-Time Prerequisites Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Tenant:        $TENANT_ID"
echo "  Mgmt App:      $MGMT_APP_NAME"
echo "  Sponsor Group: $SPONSOR_GROUP_NAME"
echo ""

# =============================================
# Step 1: Create Sponsor Security Group
# =============================================
if [[ -n "${SPONSOR_GROUP_ID:-}" ]]; then
  echo "📋 Sponsor group already set: $SPONSOR_GROUP_ID (skipping)"
else
  echo "📋 Creating sponsor security group..."

  SPONSOR_GROUP_ID=$(az ad group create \
    --display-name "$SPONSOR_GROUP_NAME" \
    --mail-nickname "$SPONSOR_GROUP_NAME" \
    --description "Sponsor group for Agent ID blueprints and agent identities" \
    --query id -o tsv)

  echo "✅ Sponsor group created: $SPONSOR_GROUP_ID"

  # Add current user as group owner
  CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
  if [[ -n "$CURRENT_USER_ID" ]]; then
    az ad group owner add --group "$SPONSOR_GROUP_ID" --owner-object-id "$CURRENT_USER_ID" 2>/dev/null || true
    az ad group member add --group "$SPONSOR_GROUP_ID" --member-id "$CURRENT_USER_ID" 2>/dev/null || true
    echo "   Added current user as owner/member"
  fi
fi
echo ""

# =============================================
# Step 2: Create Management App Registration
# =============================================
if [[ -n "${MGMT_APP_ID:-}" ]]; then
  echo "📋 Management app already set: $MGMT_APP_ID (skipping)"
  echo ""
else
  echo "📋 Creating management app registration..."

  MGMT_APP_ID=$(az ad app create \
    --display-name "$MGMT_APP_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)

  echo "✅ App created: $MGMT_APP_ID"

  # Create service principal for the app
  echo ""
  echo "📋 Creating service principal..."
  MGMT_SP_ID=$(az ad sp create --id "$MGMT_APP_ID" --query id -o tsv)
  echo "✅ Service principal created: $MGMT_SP_ID"

  # --- Step 2a: Add Application.ReadWrite.All (application permission) ---
  echo ""
  echo "🔐 Adding Application.ReadWrite.All permission..."

  # Microsoft Graph appId = 00000003-0000-0000-c000-000000000000
  # Application.ReadWrite.All (application) = 1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9
  az ad app permission add \
    --id "$MGMT_APP_ID" \
    --api 00000003-0000-0000-c000-000000000000 \
    --api-permissions 1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9=Role \
    --output none

  echo "✅ Permission added"

  # --- Step 2b: Admin consent ---
  echo ""
  echo "🔐 Granting admin consent..."

  # Wait for permission propagation
  sleep 5

  az ad app permission admin-consent --id "$MGMT_APP_ID" 2>/dev/null || {
    echo "⚠️  Auto-consent failed. Trying via Graph API..."
    # Fallback: grant via REST
    ACCESS_TOKEN=$(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)
    GRAPH_SP_ID=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv)

    curl -s -X POST \
      "https://graph.microsoft.com/v1.0/servicePrincipals/${MGMT_SP_ID}/appRoleAssignments" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -d "$(jq -n \
        --arg principalId "$MGMT_SP_ID" \
        --arg resourceId "$GRAPH_SP_ID" \
        '{
          principalId: $principalId,
          resourceId: $resourceId,
          appRoleId: "1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9"
        }')" > /dev/null
  }

  echo "✅ Admin consent granted"

  # --- Step 2c: Assign Agent ID Administrator directory role ---
  echo ""
  echo "🔐 Assigning Agent ID Administrator role..."

  ACCESS_TOKEN=$(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)

  # Look up the role definition ID
  ROLE_ID=$(curl -s \
    "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$filter=displayName%20eq%20'Agent%20ID%20Administrator'" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" | jq -r '.value[0].id // empty')

  if [[ -z "$ROLE_ID" ]]; then
    echo "⚠️  Agent ID Administrator role not found — tenant may not have Agent ID preview enabled."
    echo "   You can assign this role manually later via Entra admin center."
  else
    ASSIGN_RESPONSE=$(curl -s -X POST \
      "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -d "$(jq -n \
        --arg principalId "$MGMT_SP_ID" \
        --arg roleId "$ROLE_ID" \
        '{
          principalId: $principalId,
          roleDefinitionId: $roleId,
          directoryScopeId: "/"
        }')")

    if echo "$ASSIGN_RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
      echo "⚠️  Role assignment warning:"
      echo "$ASSIGN_RESPONSE" | jq -r '.error.message'
      echo "   You may need to assign Agent ID Administrator manually."
    else
      echo "✅ Agent ID Administrator role assigned"
    fi
  fi

  # --- Step 2d: Create client secret ---
  echo ""
  echo "🔑 Creating client secret..."

  MGMT_APP_SECRET=$(az ad app credential reset \
    --id "$MGMT_APP_ID" \
    --display-name "agent-id-demo" \
    --years 1 \
    --query password -o tsv)

  echo "✅ Client secret created (valid for 1 year)"
fi

# =============================================
# Step 3: Write to .env
# =============================================
echo ""
echo "💾 Writing prerequisites to $ENV_FILE..."

if [[ -f "$ENV_FILE" ]]; then
  # Remove any existing MGMT/SPONSOR lines to avoid duplicates
  grep -v '^MGMT_APP_ID=\|^MGMT_APP_SECRET=\|^SPONSOR_GROUP_ID=' "$ENV_FILE" > "${ENV_FILE}.tmp" || true
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
fi

cat >> "$ENV_FILE" << EOF

# --- Prerequisites (created by 00-setup-prerequisites.sh) ---
MGMT_APP_ID=${MGMT_APP_ID}
MGMT_APP_SECRET=${MGMT_APP_SECRET}
SPONSOR_GROUP_ID=${SPONSOR_GROUP_ID}
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Prerequisites setup complete"
echo ""
echo "  Management App: $MGMT_APP_ID"
echo "  Sponsor Group:  $SPONSOR_GROUP_ID"
echo ""
echo "  These are written to .env and will be used by all"
echo "  subsequent scripts. You only need to run this once."
echo ""
echo "  Next steps:"
echo "  1. Run 01-provision-function.sh"
echo "  2. Run 02-create-blueprint.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
