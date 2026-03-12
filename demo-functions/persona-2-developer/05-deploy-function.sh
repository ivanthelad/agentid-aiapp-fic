#!/usr/bin/env bash
# ============================================================================
# PERSONA 2 — Agent Development Team
# Step 05: Deploy Function App Code + Configure App Settings
#
# Prerequisites:
#   - .env with all config values
#   - Azure Functions Core Tools installed (func)
#   - Function code in ../function-app/
#
# Deploys:
#   - Python function code to Azure Function App
#   - App settings for agent identity config
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
FUNC_DIR="${SCRIPT_DIR}/../function-app"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ .env file not found. Run previous steps first."
  exit 1
fi
source "$ENV_FILE"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERSONA 2: Agent Development Team"
echo "  Deploying Function App"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# --- Step 1: Configure app settings ---
echo "⚙️  Configuring Function App settings..."
az functionapp config appsettings set \
  --resource-group "$FUNC_RESOURCE_GROUP" \
  --name "$FUNC_APP_NAME" \
  --settings \
    "TENANT_ID=${TENANT_ID}" \
    "BLUEPRINT_CLIENT_ID=${BLUEPRINT_APP_ID}" \
    "MI_CLIENT_ID=${MI_CLIENT_ID}" \
    "AGENT_IDENTITY_ID=${AGENT_IDENTITY_ID}" \
    "STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT_NAME}" \
    "STORAGE_CONTAINER=${STORAGE_CONTAINER}" \
    "AGENT_DISPLAY_NAME=${AGENT_DISPLAY_NAME:-agentid-func-agent}" \
    "ENABLE_A365_OBSERVABILITY_EXPORTER=false" \
  --output none

echo "✅ App settings configured"

# --- Step 2: Deploy function code ---
echo ""
echo "🚀 Deploying function code..."

cd "$FUNC_DIR"
func azure functionapp publish "$FUNC_APP_NAME" --python

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Function App deployed"
echo ""
echo "  URL: https://${FUNC_APP_NAME}.azurewebsites.net"
echo ""
echo "  Next steps:"
echo "  1. Run 06-verify.sh to test the function endpoints"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
