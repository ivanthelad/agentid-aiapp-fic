#!/usr/bin/env bash
# ============================================================================
# PERSONA 2 — Agent Development Team
# Step 05: Build and Deploy Demo App to AKS
#
# Prerequisites:
#   - .env populated by Persona 1 + Steps 03-04
#   - kubectl configured for the AKS cluster
#   - Docker available (or use ACR build)
#
# Deploys:
#   - ConfigMap with agent config
#   - Deployment with projected SA token volume
#   - ClusterIP Service
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
APP_DIR="${SCRIPT_DIR}/../app"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ .env file not found. Run previous steps first."
  exit 1
fi
source "$ENV_FILE"

RESOURCE_SCOPE="${RESOURCE_SCOPE:-api://AzureADTokenExchange/.default}"
IMAGE_NAME="${IMAGE_NAME:-agent-demo-app}"
ACR_NAME="${ACR_NAME:-}"
SIDECAR_IMAGE="${SIDECAR_IMAGE:-mcr.microsoft.com/entra-sdk/auth-sidecar:1.0.0-azurelinux3.0-distroless}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PERSONA 2: Agent Development Team"
echo "  Deploying Demo App to AKS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# --- Step 1: Build container image ---
if [[ -n "$ACR_NAME" ]]; then
  echo "🐳 Building image via ACR..."
  az acr build \
    --registry "$ACR_NAME" \
    --image "${IMAGE_NAME}:latest" \
    "$APP_DIR"
  FULL_IMAGE="${ACR_NAME}.azurecr.io/${IMAGE_NAME}:latest"
else
  echo "🐳 Building image locally..."
  docker build -t "${IMAGE_NAME}:latest" "$APP_DIR"
  FULL_IMAGE="${IMAGE_NAME}:latest"

  # For AKS, we need to push to a registry. Use ACR or set IMAGE_NAME to a pushed image.
  echo "⚠️  No ACR_NAME set. Using local image. Set ACR_NAME in .env for AKS deployment."
  echo "   Or set IMAGE_NAME to a pre-pushed image (e.g., myacr.azurecr.io/agent-demo-app:latest)"
fi

# --- Step 2: Deploy to Kubernetes ---
echo ""
echo "☸️  Deploying to Kubernetes..."

cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: agent-demo-config
  namespace: ${K8S_NAMESPACE}
data:
  # App config
  SIDECAR_URL: "http://localhost:5000"
  AGENT_IDENTITY_ID: "${AGENT_IDENTITY_ID:-}"
  STORAGE_ACCOUNT_NAME: "${STORAGE_ACCOUNT_NAME:-}"
  STORAGE_CONTAINER: "${STORAGE_CONTAINER:-agent-demo}"
  WRITE_INTERVAL: "${WRITE_INTERVAL:-60}"
  # Sidecar: Entra ID settings
  AzureAd__TenantId: "${TENANT_ID}"
  AzureAd__ClientId: "${BLUEPRINT_APP_ID}"
  AzureAd__ClientCredentials__0__SourceType: "SignedAssertionFilePath"
  # Sidecar: Downstream API — Storage (for blob writes)
  DownstreamApis__Storage__BaseUrl: "https://${STORAGE_ACCOUNT_NAME:-noop}.blob.core.windows.net"
  DownstreamApis__Storage__Scopes__0: "https://storage.azure.com/.default"
  DownstreamApis__Storage__RequestAppToken: "true"
  # Sidecar: Downstream API — AgentToken (for displaying agent identity claims)
  DownstreamApis__AgentToken__BaseUrl: "https://login.microsoftonline.com"
  DownstreamApis__AgentToken__Scopes__0: "api://AzureADTokenExchange/.default"
  DownstreamApis__AgentToken__RequestAppToken: "true"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agent-demo
  namespace: ${K8S_NAMESPACE}
  labels:
    app: agent-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: agent-demo
  template:
    metadata:
      labels:
        app: agent-demo
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: ${K8S_SA_NAME}
      containers:
      # --- Python demo app (zero auth code) ---
      - name: agent-demo
        image: ${FULL_IMAGE}
        ports:
        - containerPort: 8080
        envFrom:
        - configMapRef:
            name: agent-demo-config
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "128Mi"
      # --- Microsoft Entra SDK for AgentID (sidecar) ---
      # Handles: K8s JWT -> FIC exchange -> agent identity -> resource tokens
      # The AKS workload identity webhook injects AZURE_CLIENT_ID,
      # AZURE_TENANT_ID, and AZURE_FEDERATED_TOKEN_FILE automatically.
      - name: entra-sdk-sidecar
        image: ${SIDECAR_IMAGE}
        ports:
        - containerPort: 5000
        envFrom:
        - configMapRef:
            name: agent-demo-config
        env:
        - name: ASPNETCORE_URLS
          value: "http://+:5000"
        - name: Logging__LogLevel__Default
          value: "Information"
        - name: Logging__LogLevel__Microsoft.Identity.Web
          value: "Debug"
        livenessProbe:
          tcpSocket:
            port: 5000
          initialDelaySeconds: 15
          periodSeconds: 30
          failureThreshold: 5
        readinessProbe:
          tcpSocket:
            port: 5000
          initialDelaySeconds: 10
          periodSeconds: 10
          failureThreshold: 3
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "250m"
            memory: "256Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: agent-demo
  namespace: ${K8S_NAMESPACE}
spec:
  selector:
    app: agent-demo
  ports:
  - port: 80
    targetPort: 8080
  type: ClusterIP
EOF

echo "✅ Deployment applied"

# --- Step 3: Wait for pod to be ready ---
echo ""
echo "⏳ Waiting for pod to be ready..."
kubectl rollout status deployment/agent-demo \
  -n "$K8S_NAMESPACE" \
  --timeout=120s

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Demo app deployed"
echo ""
echo "  Next steps:"
echo "  1. Run 06-verify.sh to test token retrieval"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
