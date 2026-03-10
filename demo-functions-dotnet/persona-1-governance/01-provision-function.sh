#!/usr/bin/env bash
# ============================================================================
# PERSONA 1 — Central AI Governance Team
# Step 01: Provision Azure Function App (.NET 8) + User-Assigned Managed Identity
#
# Prerequisites:
#   - Logged in to test tenant: source ../az-agentid-setup.sh
#   - MGMT_APP_ID, MGMT_APP_SECRET, SPONSOR_GROUP_ID in .env
#     (run ../demo/persona-1-governance/00-setup-prerequisites.sh first)
#   - TENANT_ID, BLUEPRINT_OBJECT_ID, BLUEPRINT_APP_ID in .env
#     (copy from ../demo/.env if reusing AKS blueprint)
#
# Creates:
#   - Resource group
#   - Storage account (for Function App hosting -- NOT for agent data)
#   - Function App (.NET 8 isolated, consumption plan)
#   - User-Assigned Managed Identity
#   - Assigns MI to Function App
#
# Note: The hosting storage account is Function App infrastructure.
#       Agent data storage is created separately in step 04.
#
# Outputs:
#   - Appends Function App config and MI details to ../.env
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ .env file not found."
  echo "   Copy .env.template to .env and populate MGMT_APP_*, SPONSOR_GROUP_ID,"
  echo "   TENANT_ID, BLUEPRINT_OBJECT_ID, BLUEPRINT_APP_ID first."
  exit 1
fi
source "$ENV_FILE"

# --- Configuration ---
FUNC_RESOURCE_GROUP="${FUNC_RESOURCE_GROUP:-rg-agentid-func-dotnet}"
FUNC_APP_NAME="${FUNC_APP_NAME:-func-agentid-dotnet}"
FUNC_STORAGE_NAME="${FUNC_STORAGE_NAME:-stfuncdotnet$(( RANDOM % 90000 + 10000 ))}"
FUNC_LOCATION="${FUNC_LOCATION:-centralus}"
MI_NAME="${MI_NAME:-mi-agentid-func-dotnet}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERSONA 1: Central AI Governance Team"
echo "  Provisioning .NET Function App + Managed Identity"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Resource Group: $FUNC_RESOURCE_GROUP"
echo "  Function App:   $FUNC_APP_NAME"
echo "  MI Name:        $MI_NAME"
echo "  Location:       $FUNC_LOCATION"
echo ""

# --- Step 1: Create resource group ---
echo "📦 Creating resource group..."
az group create \
  --name "$FUNC_RESOURCE_GROUP" \
  --location "$FUNC_LOCATION" \
  --output none

echo "✅ Resource group created"

# --- Step 2: Create storage account for Function App hosting ---
echo ""
echo "📦 Creating storage account (Function App hosting)..."
az storage account create \
  --name "$FUNC_STORAGE_NAME" \
  --resource-group "$FUNC_RESOURCE_GROUP" \
  --location "$FUNC_LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --output none

echo "✅ Hosting storage account created: $FUNC_STORAGE_NAME"

# --- Step 3: Create Function App ---
echo ""
echo "⚡ Creating Function App (.NET 8 isolated)..."
az functionapp create \
  --resource-group "$FUNC_RESOURCE_GROUP" \
  --name "$FUNC_APP_NAME" \
  --storage-account "$FUNC_STORAGE_NAME" \
  --consumption-plan-location "$FUNC_LOCATION" \
  --runtime dotnet-isolated \
  --runtime-version 8.0 \
  --functions-version 4 \
  --os-type Linux \
  --output none

echo "✅ Function App created: $FUNC_APP_NAME"

# --- Step 4: Create User-Assigned Managed Identity ---
echo ""
echo "🔑 Creating User-Assigned Managed Identity..."
az identity create \
  --resource-group "$FUNC_RESOURCE_GROUP" \
  --name "$MI_NAME" \
  --output none

MI_CLIENT_ID=$(az identity show \
  --resource-group "$FUNC_RESOURCE_GROUP" \
  --name "$MI_NAME" \
  --query clientId -o tsv)

MI_PRINCIPAL_ID=$(az identity show \
  --resource-group "$FUNC_RESOURCE_GROUP" \
  --name "$MI_NAME" \
  --query principalId -o tsv)

MI_RESOURCE_ID=$(az identity show \
  --resource-group "$FUNC_RESOURCE_GROUP" \
  --name "$MI_NAME" \
  --query id -o tsv)

echo "✅ Managed Identity created"
echo "   Client ID:    $MI_CLIENT_ID"
echo "   Principal ID: $MI_PRINCIPAL_ID"

# --- Step 5: Assign MI to Function App ---
echo ""
echo "🔗 Assigning Managed Identity to Function App..."
az functionapp identity assign \
  --resource-group "$FUNC_RESOURCE_GROUP" \
  --name "$FUNC_APP_NAME" \
  --identities "$MI_RESOURCE_ID" \
  --output none

echo "✅ MI assigned to Function App"

# --- Step 6: Write config to .env ---
echo ""
echo "💾 Updating $ENV_FILE..."

cat >> "$ENV_FILE" << EOF

# --- Function App config (Persona 1 — Step 01 output) ---
FUNC_RESOURCE_GROUP=${FUNC_RESOURCE_GROUP}
FUNC_APP_NAME=${FUNC_APP_NAME}
FUNC_STORAGE_NAME=${FUNC_STORAGE_NAME}
FUNC_LOCATION=${FUNC_LOCATION}
MI_NAME=${MI_NAME}
MI_CLIENT_ID=${MI_CLIENT_ID}
MI_PRINCIPAL_ID=${MI_PRINCIPAL_ID}
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ .NET Function App + MI provisioned"
echo ""
echo "  MI Principal ID: $MI_PRINCIPAL_ID"
echo "  (This is the FIC subject for the blueprint)"
echo ""
echo "  Next steps:"
echo "  1. Run 02-add-fic-for-msi.sh (adds FIC to existing blueprint)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
