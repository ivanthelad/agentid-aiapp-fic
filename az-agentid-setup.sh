#!/usr/bin/env bash
# Azure CLI credential isolation for Agent ID test tenant
# Usage:
#   source ./az-agentid-setup.sh          # Set up isolated env + login
#   source ./az-agentid-setup.sh --reset  # Return to default credentials
#
# After sourcing, all `az` commands in this shell use the test tenant.
# Alternatively, use the `az-test` alias from any shell.

set -euo pipefail

AGENTID_AZURE_DIR="$HOME/.azure-agentid-test"

# --- Reset mode ---
if [[ "${1:-}" == "--reset" ]]; then
  unset AZURE_CONFIG_DIR 2>/dev/null || true
  echo "✅ AZURE_CONFIG_DIR unset — back to default ~/.azure credentials"
  az account show --query '{tenant:tenantId, subscription:name}' -o table 2>/dev/null || echo "  (not logged in to default profile)"
  return 0 2>/dev/null || exit 0
fi

# --- Setup mode ---
echo "🔧 Setting up isolated Azure CLI environment for Agent ID testing"
echo "   Config directory: $AGENTID_AZURE_DIR"

# Create the isolated config directory
mkdir -p "$AGENTID_AZURE_DIR"

# Point Azure CLI to the isolated directory
export AZURE_CONFIG_DIR="$AGENTID_AZURE_DIR"

# Install the alias for convenience (works in current shell)
alias az-test="AZURE_CONFIG_DIR=$AGENTID_AZURE_DIR az"

# Add alias to shell profile if not already present
SHELL_RC="$HOME/.zshrc"
[[ "$SHELL" == *bash* ]] && SHELL_RC="$HOME/.bashrc"

ALIAS_LINE="alias az-test='AZURE_CONFIG_DIR=$AGENTID_AZURE_DIR az'"
if ! grep -qF "az-test" "$SHELL_RC" 2>/dev/null; then
  echo "" >> "$SHELL_RC"
  echo "# Azure CLI alias for Agent ID test tenant (isolated credentials)" >> "$SHELL_RC"
  echo "$ALIAS_LINE" >> "$SHELL_RC"
  echo "✅ Added 'az-test' alias to $SHELL_RC"
else
  echo "ℹ️  'az-test' alias already exists in $SHELL_RC"
fi

# Check if already logged in to the isolated profile
if az account show --query tenantId -o tsv 2>/dev/null; then
  echo ""
  echo "✅ Already logged in to isolated profile:"
  az account show --query '{tenant:tenantId, subscription:name}' -o table
  echo ""
  echo "To switch tenants: az login --tenant <NEW_TENANT_ID>"
else
  echo ""
  echo "📋 Next step: Log in to your test tenant"
  echo ""
  read -p "Enter your test tenant ID (or press Enter to skip): " TENANT_ID
  if [[ -n "$TENANT_ID" ]]; then
    echo "Opening browser for authentication..."
    az login --tenant "$TENANT_ID"
    echo ""
    echo "✅ Logged in to test tenant:"
    az account show --query '{tenant:tenantId, subscription:name}' -o table
  else
    echo "Skipped login. Run 'az login --tenant <TENANT_ID>' when ready."
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  This shell now uses isolated credentials."
echo "  All 'az' commands target the test tenant."
echo ""
echo "  Commands:"
echo "    az account show         # verify current context"
echo "    source $0 --reset       # return to default credentials"
echo "    az-test <command>       # use from any shell (alias)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
