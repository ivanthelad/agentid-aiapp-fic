#!/usr/bin/env bash
# ============================================================================
# PERSONA 2 — Agent Development Team
# Step 04: Create Storage Account + Assign Agent Identity RBAC
#
# Prerequisites:
#   - .env populated by Persona 1 + Step 03
#   - Logged in to test tenant: source ../az-agentid-setup.sh
#
# Creates:
#   - Storage Account + blob container
#   - Storage Blob Data Contributor role on the AGENT IDENTITY (not blueprint)
#
# Why the agent identity gets RBAC (not the blueprint):
#   When the sidecar uses AgentIdentity param, the resulting token's oid
#   is the agent identity. Azure RBAC checks oid, so the role must be
#   on the agent identity.
#
# Outputs:
#   - Appends STORAGE_ACCOUNT_NAME, STORAGE_CONTAINER to ../.env
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ .env file not found. Run previous steps first."
  exit 1
fi
source "$ENV_FILE"

# --- Configuration ---
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-stagentiddemo$(( RANDOM % 90000 + 10000 ))}"
STORAGE_CONTAINER="${STORAGE_CONTAINER:-agent-demo}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERSONA 2: Agent Development Team"
echo "  Setting up Storage + Agent Identity RBAC"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Storage:        $STORAGE_ACCOUNT_NAME"
echo "  Agent Identity: $AGENT_IDENTITY_ID"
echo ""

# --- Step 1: Create Storage Account ---
echo "📦 Creating Storage Account..."
az storage account create \
  --name "$STORAGE_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --output none

echo "✅ Storage account created"

# --- Step 2: Create Blob Container ---
echo ""
echo "📦 Creating blob container..."
az storage container create \
  --name "$STORAGE_CONTAINER" \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --auth-mode login \
  --output none

echo "✅ Container '$STORAGE_CONTAINER' created"

# --- Step 3: Assign RBAC to Agent Identity ---
# IMPORTANT: Assign to the AGENT IDENTITY, not the blueprint.
# The sidecar's AgentIdentity param makes the token oid = agent identity.
echo ""
echo "🔐 Assigning Storage Blob Data Contributor to agent identity..."

STORAGE_ID=$(az storage account show \
  --name "$STORAGE_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id "$AGENT_IDENTITY_ID" \
  --assignee-principal-type ServicePrincipal \
  --scope "$STORAGE_ID" \
  --output none

echo "✅ RBAC assigned to agent identity: $AGENT_IDENTITY_ID"
echo "   (NOT the blueprint — the token oid is the agent identity)"

# --- Step 4: Append to .env ---
echo ""
echo "💾 Updating $ENV_FILE..."

cat >> "$ENV_FILE" << EOF

# --- Storage config (Persona 2 — Step 04 output) ---
STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT_NAME}
STORAGE_CONTAINER=${STORAGE_CONTAINER}
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Storage + RBAC ready"
echo ""
echo "  Next steps:"
echo "  1. Run 05-deploy-app.sh to build and deploy"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
