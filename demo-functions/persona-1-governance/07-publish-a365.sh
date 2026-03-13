#!/usr/bin/env bash
# =============================================================================
# 07-publish-a365.sh — Publish agent to Microsoft 365 admin center via A365 CLI
# =============================================================================
# Persona: Central AI Governance Team
#
# Prerequisites:
#   - .env populated by scripts 00-06
#   - A365 CLI installed: dotnet tool install --global Microsoft.Agents.A365.DevTools.Cli --prerelease
#   - Custom client app registered (A365_CLIENT_APP_ID in .env)
#   - Azure CLI authenticated to the correct tenant
#
# What this script does:
#   1. Reads existing blueprint/agent IDs from .env
#   2. Generates a365.config.json from existing values
#   3. Generates a365.generated.config.json from existing blueprint IDs
#   4. Runs 'a365 publish' to register the agent in Microsoft 365 admin center
#
# NOTE: a365 publish is interactive -- it opens a manifest editor and browser
#       for consent. This script prepares the config files, then hands off to
#       the CLI.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found at $ENV_FILE"
  echo "Run scripts 00-06 first."
  exit 1
fi
source "$ENV_FILE"

# ---------------------------------------------------------------------------
# Validate required variables
# ---------------------------------------------------------------------------
REQUIRED_VARS=(
  TENANT_ID SUBSCRIPTION_ID FUNC_RESOURCE_GROUP FUNC_LOCATION FUNC_APP_NAME
  A365_CLIENT_APP_ID BLUEPRINT_OBJECT_ID BLUEPRINT_APP_ID BLUEPRINT_SP_ID
  MI_PRINCIPAL_ID AGENT_DISPLAY_NAME MANAGER_EMAIL
)

for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set in .env"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Check A365 CLI is available
# ---------------------------------------------------------------------------
if ! command -v a365 &>/dev/null; then
  echo "ERROR: a365 CLI not found."
  echo "Install it with: dotnet tool install --global Microsoft.Agents.A365.DevTools.Cli --prerelease"
  exit 1
fi

echo "=== Agent 365 Publish ==="
echo "Blueprint:   $BLUEPRINT_APP_ID"
echo "Agent:       $AGENT_DISPLAY_NAME"
echo "Function:    $FUNC_APP_NAME"
echo "Tenant:      $TENANT_ID"
echo ""

# ---------------------------------------------------------------------------
# Determine tenant domain for agent UPN
# ---------------------------------------------------------------------------
TENANT_DOMAIN=$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/organization" \
  --query "value[0].verifiedDomains[?isDefault].name | [0]" -o tsv 2>/dev/null || echo "")

if [[ -z "$TENANT_DOMAIN" ]]; then
  echo "WARNING: Could not determine tenant domain. Using placeholder."
  TENANT_DOMAIN="yourtenant.onmicrosoft.com"
fi

AGENT_UPN="${AGENT_DISPLAY_NAME}@${TENANT_DOMAIN}"
echo "Agent UPN:   $AGENT_UPN"

# ---------------------------------------------------------------------------
# Generate a365.config.json
# ---------------------------------------------------------------------------
WORK_DIR="${SCRIPT_DIR}/../a365-publish"
mkdir -p "$WORK_DIR"

cat > "$WORK_DIR/a365.config.json" <<EOF
{
  "tenantId": "${TENANT_ID}",
  "subscriptionId": "${SUBSCRIPTION_ID}",
  "resourceGroup": "${FUNC_RESOURCE_GROUP}",
  "location": "${FUNC_LOCATION}",
  "environment": "prod",
  "needDeployment": false,
  "clientAppId": "${A365_CLIENT_APP_ID}",
  "webAppName": "${FUNC_APP_NAME}",
  "agentIdentityDisplayName": "${AGENT_DISPLAY_NAME} Identity",
  "agentBlueprintDisplayName": "${AGENT_DISPLAY_NAME}",
  "agentUserPrincipalName": "${AGENT_UPN}",
  "agentUserDisplayName": "${AGENT_DISPLAY_NAME} Agent User",
  "managerEmail": "${MANAGER_EMAIL}",
  "agentUserUsageLocation": "US",
  "deploymentProjectPath": ".",
  "messagingEndpoint": "https://${FUNC_APP_NAME}.azurewebsites.net/api/messages",
  "agentDescription": "Autonomous agent using Entra Agent ID two-step token exchange on Azure Functions"
}
EOF

echo "Created: $WORK_DIR/a365.config.json"

# ---------------------------------------------------------------------------
# Generate a365.generated.config.json (with existing blueprint IDs)
# ---------------------------------------------------------------------------
cat > "$WORK_DIR/a365.generated.config.json" <<EOF
{
  "managedIdentityPrincipalId": "${MI_PRINCIPAL_ID}",
  "agentBlueprintId": "${BLUEPRINT_APP_ID}",
  "agentBlueprintObjectId": "${BLUEPRINT_OBJECT_ID}",
  "agentBlueprintServicePrincipalObjectId": "${BLUEPRINT_SP_ID}",
  "completed": true,
  "completedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cliVersion": "$(a365 --version 2>/dev/null || echo 'unknown')"
}
EOF

echo "Created: $WORK_DIR/a365.generated.config.json"

# ---------------------------------------------------------------------------
# Run a365 publish from the work directory
# ---------------------------------------------------------------------------
echo ""
echo "=== Running a365 publish ==="
echo "Working directory: $WORK_DIR"
echo ""
echo "NOTE: This is interactive. The CLI will:"
echo "  1. Update manifest.json with your blueprint ID"
echo "  2. Open your editor to customize the manifest"
echo "  3. Package and upload to Microsoft 365 admin center"
echo "  4. Open browser windows for admin consent"
echo ""

cd "$WORK_DIR"
a365 publish
