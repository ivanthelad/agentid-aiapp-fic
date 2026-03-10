#!/usr/bin/env bash
# ============================================================================
# PERSONA 2 — Agent Development Team
# Step 06: Verify Function App Endpoints
#
# Tests:
#   - /api/health       — liveness probe
#   - /api/write-status — performs live blob write via two-step token exchange
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ .env file not found. Run previous steps first."
  exit 1
fi
source "$ENV_FILE"

FUNC_URL="https://${FUNC_APP_NAME}.azurewebsites.net"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERSONA 2: Agent Development Team"
echo "  Verifying Function App"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Function URL: $FUNC_URL"
echo ""

# --- Step 1: Health check ---
echo "🏥 Step 1: Health check..."
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "${FUNC_URL}/api/health" --max-time 10)
if [[ "$HEALTH" == "200" ]]; then
  echo "   ✅ Health: OK (200)"
else
  echo "   ❌ Health: HTTP $HEALTH"
  echo "   Function may still be starting up. Wait 30s and retry."
fi

# --- Step 2: Write status (live blob write) ---
echo ""
echo "📝 Step 2: Blob write via two-step token exchange..."
WRITE_RESULT=$(curl -s "${FUNC_URL}/api/write-status" --max-time 30)
echo "$WRITE_RESULT" | python3 -m json.tool 2>/dev/null || echo "$WRITE_RESULT"

STATUS=$(echo "$WRITE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")

echo ""
if [[ "$STATUS" == "success-write" ]]; then
  echo "   ✅ Blob write: SUCCESS"
  echo "   The agent identity has storage access via two-step token exchange."
else
  echo "   ❌ Blob write: FAILED"
  echo "   Check Function App logs: az functionapp log tail --name $FUNC_APP_NAME --resource-group $FUNC_RESOURCE_GROUP"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Verification complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
