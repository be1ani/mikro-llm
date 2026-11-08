#!/usr/bin/env bash
# Fresh install of the LLM platform: kind -> Argo CD -> Envoy Gateway -> Gateway -> ApplicationSet -> models.
# Safe to re-run: every step is idempotent.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ---- Configuration ---------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-mikro-llm}"
# Pin these. Find your current ones with: helm list -A   (CHART column, e.g. argo-cd-9.0.0)
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.14.0}"
EG_CHART_VERSION="${EG_CHART_VERSION:-1.10.0}"          # e.g. v1.5.0
PRELOAD_IMAGES="${PRELOAD_IMAGES:-true}"          # pull on host + kind load (helps on slow networks)
APPSET_FILE="${APPSET_FILE:-argocd/application-set-models.yaml}"
MODEL_WAIT="${MODEL_WAIT:-40m}"                   # first start downloads the image and the weights

# ---- Helpers ---------------------------------------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 0. Preflight ----------------------------------------------------------
log "Preflight checks"
for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null || die "$bin not found (run ./install-deps.sh)"
done
docker info >/dev/null 2>&1 || die "Docker daemon is not running"
[ -n "$ARGOCD_CHART_VERSION" ] || die "Set ARGOCD_CHART_VERSION (see 'helm list -A')"
[ -n "$EG_CHART_VERSION" ]     || die "Set EG_CHART_VERSION (see 'helm list -A')"
for f in cluster/kind-config.yaml gateway/gateway.yaml "$APPSET_FILE"; do
  [ -f "$f" ] || die "Missing file: $f"
done

# ---- 1. Cluster ------------------------------------------------------------
log "kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster already exists, reusing it"
else
  kind create cluster --name "$CLUSTER_NAME" --config cluster/kind-config.yaml
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=5m

# ---- 2. Helm repo ----------------------------------------------------------
log "Helm repositories"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo update >/dev/null

# ---- 3. Preload images (optional) -----------------------------------------
if [ "$PRELOAD_IMAGES" = "true" ]; then
  log "Preloading images into kind (set PRELOAD_IMAGES=false to skip)"
  images=$(
    {
      helm template argocd argo/argo-cd -n argocd --version "$ARGOCD_CHART_VERSION"
      for f in models/*.yaml; do
        helm template "$(basename "$f" .yaml)" charts/model-server -f "$f"
      done
    } | awk '/^[[:space:]]*image:/ {gsub(/"/, "", $2); print $2}' | sort -u
  )
  for img in $images; do
    echo "-> $img"
    docker image inspect "$img" >/dev/null 2>&1 || docker pull "$img" || { warn "pull failed: $img"; continue; }
    kind load docker-image "$img" --name "$CLUSTER_NAME" || warn "kind load failed for $img (cluster will pull it itself)"
  done
fi

# ---- 4. Argo CD ------------------------------------------------------------
log "Installing Argo CD $ARGOCD_CHART_VERSION"
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace \
  --version "$ARGOCD_CHART_VERSION" \
  --timeout 15m --wait

# ---- 5. Envoy Gateway ------------------------------------------------------
log "Installing Envoy Gateway $EG_CHART_VERSION"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  -n envoy-gateway-system --create-namespace \
  --version "$EG_CHART_VERSION" \
  --timeout 15m --wait
kubectl -n envoy-gateway-system wait --for=condition=Available deployment/envoy-gateway --timeout=5m
kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=2m

# ---- 6. GatewayClass + Gateway --------------------------------------------
log "Applying gateway/"
kubectl apply -f gateway/gateway.yaml

# ---- 7. ApplicationSet -----------------------------------------------------
log "Applying ApplicationSet ($APPSET_FILE)"
kubectl -n argocd wait --for=condition=Available deployment/argocd-applicationset-controller --timeout=5m
kubectl apply -f "$APPSET_FILE"

# ---- 8. Wait for model Applications ---------------------------------------
log "Waiting for Applications to appear"
for _ in $(seq 1 60); do
  apps=$(kubectl -n argocd get applications -o name 2>/dev/null || true)
  [ -n "$apps" ] && break
  sleep 5
done
[ -n "${apps:-}" ] || die "No Argo CD Applications created. Is the repo pushed to GitHub? Check: kubectl -n argocd describe applicationset models"

log "Waiting for Applications to sync and become healthy (up to $MODEL_WAIT)"
echo "Watch progress in another terminal: kubectl -n llm-models get pods -w"
for app in $apps; do
  kubectl -n argocd wait "$app" --for=jsonpath='{.status.sync.status}'=Synced --timeout=10m
  kubectl -n argocd wait "$app" --for=jsonpath='{.status.health.status}'=Healthy --timeout="$MODEL_WAIT"
done

# ---- Done ------------------------------------------------------------------
log "Platform is up"
cat <<EOF

Argo CD admin password:
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

Port-forward the gateway (kind has no external LoadBalancer IP):
  make forward

Then test:
  curl http://localhost:8888/gemma-1b/v1/models
EOF
