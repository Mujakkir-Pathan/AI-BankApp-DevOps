#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-us-west-2}"
CLUSTER="${CLUSTER:-bankapp-eks}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.1}"
EG_VERSION="${EG_VERSION:-v1.2.6}"

cd "$(dirname "$0")/.."

say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }

# --- 0. Preflight ---
say "Preflight"

for bin in kubectl helm aws git jq; do
  command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }
done

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
ok "kubeconfig -> $(kubectl config current-context)"

kubectl get nodes >/dev/null
ok "$(kubectl get nodes --no-headers | wc -l | tr -d ' ') nodes reachable"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if ! git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  echo "Branch '$BRANCH' is not on origin. ArgoCD can only sync what it can fetch."
  echo "  git push -u origin $BRANCH"
  exit 1
fi
if [ -n "$(git log "origin/$BRANCH..$BRANCH" --oneline)" ]; then
  warn "local commits not yet pushed — ArgoCD will deploy the REMOTE state"
fi
ok "branch '$BRANCH' is on origin"

if ! aws secretsmanager get-secret-value \
      --secret-id "${BANKAPP_SECRET:-bankapp/mysql}" --region "$REGION" >/dev/null 2>&1; then
  echo "Secrets Manager secret 'bankapp/mysql' has no value yet."
  echo "Run the 'set_bankapp_secret' command from: terraform output"
  echo "  cd terraform && terraform output -raw set_bankapp_secret | bash"
  exit 1
fi
ok "bankapp/mysql has a value"

# --- 1. Gateway API + Envoy Gateway ---
say "Gateway API ($GATEWAY_API_VERSION)"
kubectl apply --server-side \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
ok "CRDs applied"

say "Envoy Gateway ($EG_VERSION)"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "$EG_VERSION" \
  -n envoy-gateway-system --create-namespace \
  --skip-crds \
  --wait --timeout 10m >/dev/null
ok "controller ready"

# The chart passes --skip-crds above, so the extension CRDs come from the
# chart's generated/ directory (EnvoyProxy, BackendTrafficPolicy, ...).
say "Envoy Gateway extension CRDs"
helm pull oci://docker.io/envoyproxy/gateway-helm --version "$EG_VERSION" --untar -d /tmp/eg-chart >/dev/null
kubectl apply --server-side -f /tmp/eg-chart/gateway-helm/crds/generated/ >/dev/null
kubectl rollout restart deployment envoy-gateway -n envoy-gateway-system >/dev/null
kubectl rollout status deployment envoy-gateway -n envoy-gateway-system --timeout=5m >/dev/null
ok "extension CRDs applied, controller rolled"

# --- 2. Platform (app-of-apps) ---
say "Platform: ESO + cert-manager + observability"
kubectl apply -f gitops/argocd/platform.yaml >/dev/null
ok "app-of-apps applied — ArgoCD is now creating its children"

wait_for() { # wait_for <namespace> <resource> [timeout-seconds]
  local ns="$1" res="$2" limit="${3:-600}" waited=0
  until kubectl -n "$ns" get "$res" >/dev/null 2>&1; do
    [ "$waited" -ge "$limit" ] && return 1
    sleep 10; waited=$((waited + 10))
  done
}

say "Waiting for External Secrets Operator"
if wait_for external-secrets deploy/external-secrets 600 &&
   kubectl -n external-secrets rollout status deploy/external-secrets --timeout=8m >/dev/null 2>&1; then
  ok "ESO ready"
else
  warn "not ready — check: kubectl -n argocd get app external-secrets"
fi

say "Waiting for cert-manager"
if wait_for cert-manager deploy/cert-manager 600 &&
   kubectl -n cert-manager rollout status deploy/cert-manager --timeout=8m >/dev/null 2>&1; then
  ok "cert-manager ready"
  # The chart passes gatewayAPI via --config, not a CLI flag, so read the
  # ControllerConfiguration ConfigMap rather than the container args.
  kubectl -n cert-manager get cm cert-manager \
    -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
    | grep -A1 'gatewayAPI' | grep -q 'enabled: true' \
    && ok "Gateway API support on" \
    || warn "Gateway API support off: restart it (kubectl -n cert-manager rollout restart deploy cert-manager)"
else
  warn "not ready — check: kubectl -n argocd get app cert-manager"
fi

# A manual kube-prometheus release (the old pre-GitOps install) in namespace
# 'monitoring' would fight the platform's operator over the CRDs — pick one.
if helm status kube-prometheus -n monitoring >/dev/null 2>&1; then
  warn "manual kube-prometheus release detected in ns 'monitoring'"
  warn "uninstall it first or skip: kubectl -n argocd get app observability-prometheus"
fi

# --- 3. The application ---
say "BankApp (raw manifests -> namespace 'bankapp')"
kubectl apply -f argocd/application.yml >/dev/null
ok "bankapp Application applied"

# --- 4. Verify ---
say "Waiting for the app to settle"

if wait_for bankapp deploy/bankapp 600 &&
   kubectl -n bankapp wait --for=condition=available --timeout=10m \
     deploy/bankapp deploy/mysql deploy/ollama >/dev/null 2>&1; then
  ok "bankapp, mysql and ollama available"
else
  warn "app not ready — see the PVC/secret checks below"
fi

say "Status"

echo "--- ArgoCD applications ---"
kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null

echo
echo "--- PersistentVolumeClaims (all must be Bound, not Pending) ---"
kubectl get pvc -A 2>/dev/null

echo
echo "--- the Secret ESO built from AWS ---"
kubectl -n bankapp get secret bankapp-secret \
  -o jsonpath='{.data}' 2>/dev/null | tr ',' '\n' | cut -d'"' -f2 | sed 's/^/    /'

echo
echo "--- pods ---"
kubectl get pods -A 2>/dev/null \
  | grep -E 'NAMESPACE|^bankapp |^observability |^external-secrets |^cert-manager |^envoy' | head -40

say "Public URL"
ADDR=""
for i in $(seq 1 30); do
  ADDR="$(kubectl -n bankapp get gateway bankapp-gateway \
          -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  [ -n "$ADDR" ] && break
  sleep 10
done

if [ -n "$ADDR" ]; then
  ok "https://$ADDR"
  echo
  echo "    curl -s https://$ADDR/actuator/health"
  echo
  echo "    kubectl -n observability port-forward svc/observability-grafana 3000:80"
  echo "    (Grafana: admin / bankapp — gitops/observability/grafana-values.yaml)"
else
  warn "Gateway has no address yet: kubectl -n bankapp get gateway bankapp-gateway"
fi

say "Done. Tear down per Deploy.md — namespaces BEFORE terraform destroy."
