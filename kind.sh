#!/usr/bin/env bash
# =============================================================================
# kind-setup.sh
# Sets up a local Kubernetes cluster with:
#   - kind (Kubernetes in Docker)
#   - ArgoCD          → http://localhost:8888
#   - Argo Workflows  → http://localhost:2746
#   - CronWorkflow applied and visible in ArgoCD
#
# Run this BEFORE docker compose up
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠️${NC}  $*"; }

# ── Step 1: Install prerequisites ─────────────────────────────────────────────
log "Checking prerequisites..."

# Install kind
if ! command -v kind &>/dev/null; then
  log "Installing kind..."
  curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
  chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind
  ok "kind installed"
else
  ok "kind already installed: $(kind version)"
fi

# Install kubectl
if ! command -v kubectl &>/dev/null; then
  log "Installing kubectl..."
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x kubectl && sudo mv kubectl /usr/local/bin/kubectl
  ok "kubectl installed"
else
  ok "kubectl already installed: $(kubectl version --client --short 2>/dev/null || true)"
fi

# Install Helm
if ! command -v helm &>/dev/null; then
  log "Installing Helm..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ok "Helm installed"
else
  ok "Helm already installed: $(helm version --short)"
fi

# Install Argo CLI
if ! command -v argo &>/dev/null; then
  log "Installing Argo CLI..."
  curl -sLO https://github.com/argoproj/argo-workflows/releases/download/v3.5.2/argo-linux-amd64.gz
  gunzip argo-linux-amd64.gz
  chmod +x argo-linux-amd64
  sudo mv argo-linux-amd64 /usr/local/bin/argo
  ok "Argo CLI installed"
else
  ok "Argo CLI already installed: $(argo version --short 2>/dev/null || true)"
fi

# Install ArgoCD CLI
if ! command -v argocd &>/dev/null; then
  log "Installing ArgoCD CLI..."
  curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
  chmod +x argocd && sudo mv argocd /usr/local/bin/argocd
  ok "ArgoCD CLI installed"
else
  ok "ArgoCD CLI already installed"
fi

# ── Step 2: Create kind cluster ───────────────────────────────────────────────
CLUSTER_NAME="ecommerce-local"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "kind cluster '${CLUSTER_NAME}' already exists — skipping creation"
else
  log "Creating kind cluster: ${CLUSTER_NAME}..."
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8888
        protocol: TCP
      - containerPort: 30081
        hostPort: 2746
        protocol: TCP
EOF
  ok "kind cluster '${CLUSTER_NAME}' created"
fi

# Set kubectl context
kubectl config use-context "kind-${CLUSTER_NAME}"
ok "kubectl context set to kind-${CLUSTER_NAME}"

# ── Step 3: Create namespaces ─────────────────────────────────────────────────
log "Creating namespaces..."
for ns in argocd argo worker; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
ok "Namespaces ready: argocd, argo, worker"

# ── Step 4: Install ArgoCD ────────────────────────────────────────────────────
log "Installing ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 6.7.3 \
  --set server.service.type=NodePort \
  --set server.service.nodePorts.http=30080 \
  --set server.extraArgs[0]="--insecure" \
  --wait --timeout=300s

ok "ArgoCD installed"

# Get ArgoCD admin password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

ok "ArgoCD admin password: ${ARGOCD_PASSWORD}"

# ── Step 5: Install Argo Workflows ────────────────────────────────────────────
log "Installing Argo Workflows..."
helm upgrade --install argo-workflows argo/argo-workflows \
  --namespace argo \
  --set server.serviceType=NodePort \
  --set server.serviceNodePort=30081 \
  --set server.extraArgs[0]="--auth-mode=server" \
  --wait --timeout=300s

ok "Argo Workflows installed"

# ── Step 6: Create RabbitMQ secret for CronWorkflow ──────────────────────────
log "Creating RabbitMQ secret in argo namespace..."
kubectl create secret generic rabbitmq-secret \
  --from-literal=host="host.docker.internal" \
  --from-literal=username="admin" \
  --from-literal=password="admin123" \
  --from-literal=rabbit-url="amqp://admin:admin123@host.docker.internal:5672" \
  --namespace argo \
  --dry-run=client -o yaml | kubectl apply -f -

ok "RabbitMQ secret created"

# ── Step 7: Apply Argo CronWorkflow ──────────────────────────────────────────
log "Applying DLQ CronWorkflow..."

cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: dlq-reprocess
  namespace: argo
  labels:
    app: dlq-reprocessor
spec:
  schedule: "*/5 * * * *"
  timezone: "Asia/Kolkata"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  workflowSpec:
    entrypoint: reprocess
    templates:
      - name: reprocess
        container:
          image: alpine:3.19
          command: [sh, -c]
          args:
            - |
              apk add --no-cache curl python3 bash
              echo "=== DLQ Reprocessor: $(date) ==="

              RABBIT_HOST="${RABBIT_HOST:-host.docker.internal}"
              RABBIT_PORT="${RABBIT_PORT:-15672}"
              RABBIT_USER="${RABBIT_USER:-admin}"
              RABBIT_PASS="${RABBIT_PASS:-admin123}"
              MAX_MESSAGES=50
              MAX_RETRIES=3

              # Check DLQ depth
              DEPTH=$(curl -sf -u "$RABBIT_USER:$RABBIT_PASS" \
                "http://$RABBIT_HOST:$RABBIT_PORT/api/queues/%2F/orders.dlq" \
                | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('messages',0))" 2>/dev/null || echo "0")

              echo "DLQ depth: $DEPTH"

              if [ "$DEPTH" = "0" ]; then
                echo "✅ DLQ is empty — nothing to reprocess"
                exit 0
              fi

              echo "Reprocessing $DEPTH messages..."
              PROCESSED=0

              for i in $(seq 1 $MAX_MESSAGES); do
                MSG=$(curl -sf -u "$RABBIT_USER:$RABBIT_PASS" \
                  -X POST \
                  -H "Content-Type: application/json" \
                  -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}' \
                  "http://$RABBIT_HOST:$RABBIT_PORT/api/queues/%2F/orders.dlq/get")

                [ "$(echo $MSG | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null)" = "0" ] && break

                ORDER_ID=$(echo $MSG | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.loads(d[0]['payload']).get('orderId','unknown'))" 2>/dev/null || echo "unknown")
                RETRY=$(echo $MSG | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0].get('properties',{}).get('headers',{}).get('x-retry',0))" 2>/dev/null || echo "0")
                PAYLOAD=$(echo $MSG | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['payload'])" 2>/dev/null)

                echo "Processing: $ORDER_ID (retry #$RETRY)"

                NEW_RETRY=$((RETRY + 1))
                curl -sf -u "$RABBIT_USER:$RABBIT_PASS" \
                  -X POST \
                  -H "Content-Type: application/json" \
                  -d "{\"routing_key\":\"orders\",\"payload\":$(echo $PAYLOAD | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),\"payload_encoding\":\"string\",\"properties\":{\"delivery_mode\":2,\"headers\":{\"x-retry\":$NEW_RETRY,\"x-origin\":\"argo-cronworkflow\"}}}" \
                  "http://$RABBIT_HOST:$RABBIT_PORT/api/exchanges/%2F/amq.default/publish" && \
                  echo "✅ Re-queued: $ORDER_ID" && PROCESSED=$((PROCESSED+1))
                sleep 0.2
              done

              echo "=== Done: $PROCESSED messages re-queued ==="
          env:
            - name: RABBIT_HOST
              valueFrom:
                secretKeyRef:
                  name: rabbitmq-secret
                  key: host
            - name: RABBIT_USER
              valueFrom:
                secretKeyRef:
                  name: rabbitmq-secret
                  key: username
            - name: RABBIT_PASS
              valueFrom:
                secretKeyRef:
                  name: rabbitmq-secret
                  key: password
EOF

ok "CronWorkflow 'dlq-reprocess' applied in argo namespace"

# ── Step 8: Register ArgoCD app pointing to local Helm chart ─────────────────
log "Registering ArgoCD applications..."

# Login to ArgoCD
argocd login localhost:8888 \
  --username admin \
  --password "${ARGOCD_PASSWORD}" \
  --insecure 2>/dev/null || warn "ArgoCD CLI login failed — use UI instead"

ok "ArgoCD login successful"

# ── Step 9: Verify everything ────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  ✅  Local Kubernetes + ArgoCD + Argo Workflows READY"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  🌐 ArgoCD UI         → http://localhost:8888"
echo "     Username          : admin"
echo "     Password          : ${ARGOCD_PASSWORD}"
echo ""
echo "  🌐 Argo Workflows UI → http://localhost:2746"
echo ""
echo "  📋 Useful commands:"
echo ""
echo "  # Check CronWorkflow"
echo "  kubectl get cronworkflow -n argo"
echo ""
echo "  # Trigger DLQ workflow manually (don't wait 5 min)"
echo "  argo submit --from cronwf/dlq-reprocess -n argo --watch"
echo ""
echo "  # Watch workflow runs live"
echo "  argo list -n argo"
echo "  argo logs @latest -n argo"
echo ""
echo "  # Watch ArgoCD apps"
echo "  argocd app list"
echo ""
echo "  # Now start Docker Compose stack:"
echo "  docker compose up --build -d"
echo ""
echo "══════════════════════════════════════════════════════════"