#!/usr/bin/env bash
# ============================================================================
# PERSONA 2 — Agent Development Team
# Step 06: Verify Blob Writes
#
# Tests the deployed app by port-forwarding and calling:
#   /write-status — verifies blob writes with agent identity RBAC
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ .env file not found."
  exit 1
fi
source "$ENV_FILE"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERSONA 2: Agent Development Team"
echo "  Verifying Blob Writes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# --- Step 1: Check pod status ---
echo "📋 Pod status:"
kubectl get pods -n "$K8S_NAMESPACE" -l app=agent-demo
echo ""

# --- Step 2: Port-forward and test ---
echo "🔗 Starting port-forward (background)..."
kubectl port-forward -n "$K8S_NAMESPACE" "svc/agent-demo" 8080:80 &
PF_PID=$!
sleep 3

# --- Step 3: Test blob writes ---
echo ""
echo "📡 Testing /write-status (blob writes with agent identity RBAC)..."
echo ""

WRITE_RESPONSE=$(curl -s http://localhost:8080/write-status 2>/dev/null || echo '{"error": "Connection failed"}')
echo "$WRITE_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$WRITE_RESPONSE"

LAST_RESULT=$(echo "$WRITE_RESPONSE" | jq -r '.last_result // "unknown"' 2>/dev/null)
if [[ "$LAST_RESULT" == "success-write" ]]; then
  echo ""
  echo "✅ Blob write: SUCCESS"
elif [[ "$LAST_RESULT" == "pending" ]]; then
  echo ""
  echo "⏳ Blob write: PENDING (first write happens after ${WRITE_INTERVAL:-60}s)"
else
  echo ""
  echo "❌ Blob write: FAILED — last_result=$LAST_RESULT"
fi

# --- Cleanup ---
echo ""
echo "🧹 Stopping port-forward..."
kill $PF_PID 2>/dev/null || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Verification complete"
echo ""
echo "  /write-status — blob writes prove RBAC on agent identity"
echo ""
echo "  See docs/demo-disable-verify.md for governance demo"
echo "  (disable FIC → verify failure → re-enable)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
