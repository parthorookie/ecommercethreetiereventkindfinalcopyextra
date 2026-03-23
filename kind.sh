#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠️${NC}  $*"; }

# ── OS Detection ─────────────────────────────────────────
OS="$(uname | tr '[:upper:]' '[:lower:]')"

if [[ "$OS" == *"mingw"* || "$OS" == *"msys"* || "$OS" == *"cygwin"* ]]; then
  PLATFORM="windows"
elif [[ "$OS" == *"darwin"* ]]; then
  PLATFORM="mac"
else
  PLATFORM="linux"
fi

log "Detected platform: $PLATFORM"

BIN_DIR="./bin"
mkdir -p "$BIN_DIR"
export PATH="$PWD/$BIN_DIR:$PATH"

# ── Helper: Install binary safely ────────────────────────
install_binary () {
  local name=$1
  local url=$2
  local output=$3

  if command -v "$name" &>/dev/null; then
    ok "$name already installed in system"
    return
  fi

  if [ -f "$BIN_DIR/$output" ]; then
    ok "$name already exists in ./bin"
    return
  fi

  log "Installing $name..."
  curl -Lo "$BIN_DIR/$output" "$url"
  chmod +x "$BIN_DIR/$output"
  ok "$name installed in ./bin"
}

# ── Step 1: Install tools ────────────────────────────────

if [[ "$PLATFORM" == "windows" ]]; then
  install_binary "kind" \
    "https://kind.sigs.k8s.io/dl/v0.20.0/kind-windows-amd64" \
    "kind.exe"

  install_binary "kubectl" \
    "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/windows/amd64/kubectl.exe" \
    "kubectl.exe"

  install_binary "argo" \
    "https://github.com/argoproj/argo-workflows/releases/download/v3.5.2/argo-windows-amd64.exe" \
    "argo.exe"

  install_binary "argocd" \
    "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-windows-amd64.exe" \
    "argocd.exe"

else
  install_binary "kind" \
    "https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64" \
    "kind"

  install_binary "kubectl" \
    "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    "kubectl"

  install_binary "argo" \
    "https://github.com/argoproj/argo-workflows/releases/download/v3.5.2/argo-linux-amd64" \
    "argo"

  install_binary "argocd" \
    "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64" \
    "argocd"
fi

# Helm
if ! command -v helm &>/dev/null; then
  log "Installing Helm..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || warn "Helm install failed"
else
  ok "Helm already installed"
fi

# ── FIX: Resolve correct kind binary ─────────────────────
if command -v kind &>/dev/null; then
  KIND_BIN=$(command -v kind)
elif [ -f "$BIN_DIR/kind.exe" ]; then
  KIND_BIN="$BIN_DIR/kind.exe"
elif [ -f "$BIN_DIR/kind" ]; then
  KIND_BIN="$BIN_DIR/kind"
else
  echo "❌ kind not found"
  exit 1
fi

ok "Using kind binary: $KIND_BIN"

# ── Step 2: Create kind cluster ──────────────────────────
CLUSTER_NAME="ecommerce-local"

if "$KIND_BIN" get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster exists, skipping..."
else
  log "Creating kind cluster..."

  cat <<EOF | "$KIND_BIN" create cluster --name "${CLUSTER_NAME}" --config=-
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
      - containerPort: 30081
        hostPort: 2746
EOF

  ok "Cluster created"
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

# ── Step 3: Namespaces ───────────────────────────────────
for ns in argocd argo worker; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

ok "Namespaces ready"

# ── Step 4: ArgoCD ───────────────────────────────────────
helm repo add argo https://argoproj.github.io/argo-helm || true
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=NodePort \
  --set server.service.nodePorts.http=30080 \
  --set server.extraArgs[0]="--insecure" \
  --wait

ok "ArgoCD installed"

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

# ── Step 5: Argo Workflows ───────────────────────────────
helm upgrade --install argo-workflows argo/argo-workflows \
  --namespace argo \
  --set server.serviceType=NodePort \
  --set server.serviceNodePort=30081 \
  --set server.extraArgs[0]="--auth-mode=server" \
  --wait

ok "Argo Workflows installed"

# ── Step 6: RabbitMQ Secret ──────────────────────────────
kubectl create secret generic rabbitmq-secret \
  --from-literal=host="host.docker.internal" \
  --from-literal=username="admin" \
  --from-literal=password="admin123" \
  --namespace argo \
  --dry-run=client -o yaml | kubectl apply -f -

ok "RabbitMQ secret created"

# ── Step 7: CronWorkflow ─────────────────────────────────
kubectl apply -f cronworkflow.yaml || warn "cronworkflow.yaml missing"

# ── DONE ────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════"
echo "✅ ENV READY"
echo "═══════════════════════════════════════"
echo "ArgoCD: http://localhost:8888"
echo "User: admin"
echo "Pass: $ARGOCD_PASSWORD"
echo ""
echo "Argo Workflows: http://localhost:2746"
echo ""
echo "Run:"
echo "docker compose up --build -d"
echo "═══════════════════════════════════════"
