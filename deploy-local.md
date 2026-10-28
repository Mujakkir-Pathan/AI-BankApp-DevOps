# Local Deployment — full Kubernetes + GitOps, no AWS

Everything [`Deploy.md`](Deploy.md) does on EKS, but on a local **kind**
cluster: Gateway API + Envoy Gateway, ArgoCD, the app-of-apps platform
(External Secrets, cert-manager, Prometheus/Grafana/Loki/Tempo, OTel
collectors, dashboards) and the BankApp itself. **No AWS anywhere** — no EKS,
no Terraform, no S3, no Secrets Manager, no NLB.

> Just want the JVM + MySQL + Ollama with no Kubernetes at all?
> `make setup && make up` (see [README](README.md) / `Makefile`).

## What replaces the AWS pieces

The repo manifests stay **untouched** — GitOps syncs the same `k8s/` and
`gitops/` files as EKS. Only these three local substitutes are added, because
they are the parts that intrinsically need AWS or public DNS:

| EKS (Deploy.md) | Local (this doc) | Why |
|---|---|---|
| VPC + EKS + ArgoCD via Terraform | `kind create cluster` | no cloud at all |
| S3 remote state (`terraform/`) | not needed | no Terraform |
| AWS Secrets Manager + `external-secrets-config` app | **fake `ClusterSecretStore`**, same name `aws-secrets-manager` | `k8s/external-secret.yml` reconciles unmodified |
| EBS CSI `gp3` StorageClass | **static hostPath PVs** labelled `storageClassName: gp3` | `k8s/pvc.yml` + Prometheus/Loki/Tempo values pin `gp3` |
| Let's Encrypt (HTTP-01, public DNS) | **pre-created self-signed `bankapp-tls` Secret** | ACME validation can't reach localhost |
| AWS NLB | **MetalLB** (L2) → an IP on the kind docker network | kind has no LoadBalancer support built in |

Everything else — waves, Helm values, dashboards, ServiceMonitors,
PrometheusRule, EnvoyProxy telemetry, RBAC — is the real thing.

## Prerequisites

Docker, [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation),
`kubectl`, `Helm 3`, `openssl`. kind nodes are plain Docker containers with
no memory cap of their own — give Docker **≥10 GB** (Docker Desktop:
Settings → Resources). The stack is heavy: Ollama (2.5Gi) + 4 app replicas +
Prometheus (2Gi) + Loki/Tempo.

## Step 1 — cluster + MetalLB + metrics-server

```bash
kind create cluster

# --- LoadBalancer support (kind has none built in; replaces the AWS NLB) ---
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=ready pod \
  --selector=app=metallb --timeout=90s

# Pool must sit INSIDE the kind docker network — read the subnet, then
# set start/end to match (172.18.x is the usual default; adjust if yours differs)
docker network inspect kind -f '{{(index .IPAM.Config 0).Subnet}}'

kubectl apply -f - <<'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - 172.18.0.100-172.18.0.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
EOF

# --- metrics-server (HPA needs it; kind ships without it) ---
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

## Step 2 — Gateway API + Envoy Gateway

Identical to EKS (`scripts/deploy.sh` runs the same block):

```bash
kubectl apply --server-side \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.6 -n envoy-gateway-system --create-namespace --skip-crds --wait

helm pull oci://docker.io/envoyproxy/gateway-helm --version v1.2.6 --untar -d /tmp/eg-chart
kubectl apply --server-side -f /tmp/eg-chart/gateway-helm/crds/generated/
kubectl -n envoy-gateway-system rollout restart deploy/envoy-gateway
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=5m

# Envoy's LoadBalancer service should now get a MetalLB IP:
kubectl -n envoy-gateway-system get svc
```

## Step 3 — ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace --wait

kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo     # admin password

# UI (optional): https://localhost:8080 — self-signed cert, admin/<password>
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

## Step 4 — platform (GitOps), minus the two AWS/DNS apps

These are the **same Application CRs** the app-of-apps parent
(`gitops/argocd/platform.yaml`, applied by `deploy.sh` on EKS) creates —
applied directly here so the two AWS-backed children can be left out:

```bash
kubectl apply -f gitops/argocd/platform/external-secrets.yaml    # ESO (CRDs)
kubectl apply -f gitops/argocd/platform/cert-manager.yaml        # cert-manager

for f in observability-prometheus observability-loki observability-tempo \
         observability-collector-gateway observability-collector-agent \
         observability-grafana observability-config observability-dashboards; do
  kubectl apply -f "gitops/argocd/platform/$f.yaml"
done

# NOT applied locally (skip these two):
#   external-secrets-config.yaml  -> AWS Secrets Manager store
#   cert-manager-config.yaml      -> public Let's Encrypt staging issuer

kubectl -n external-secrets rollout status deploy/external-secrets --timeout=8m
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=8m
```

> First minutes are noisy: `observability-config` (EnvoyProxy → GatewayClass
> paramsRef) can sync before the GatewayClass exists, cert-manager needs the
> Gateway API CRDs at startup. ArgoCD retries — watch
> `kubectl -n argocd get applications` until everything is `Synced/Healthy`.
> The 6 git-sourced config apps point at
> `https://github.com/Mujakkir-Pathan/AI-BankApp-DevOps.git @ main` — if you
> deploy from another fork, edit `repoURL` in those manifests first.

## Step 5 — the three local substitutes

### a. Secret store (replaces AWS Secrets Manager)

Same **name** as the EKS store, so `k8s/external-secret.yml`
(`secretStoreRef: aws-secrets-manager`) resolves without edits. The ESO
`fake` provider just returns the JSON that `terraform output
set_bankapp_secret` would have written to AWS:

```bash
kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    fake:
      data:
        - key: bankapp/mysql
          value: '{"MYSQL_ROOT_PASSWORD":"Test@123","MYSQL_USER":"root","MYSQL_PASSWORD":"Test@123"}'
EOF
```

### b. Static PVs (replaces EBS CSI / `gp3`)

`k8s/pvc.yml` (mysql 5Gi, ollama 10Gi) and the Prometheus/Loki/Tempo values
all pin `storageClassName: gp3` — there is no EBS on kind, so PVCs would sit
`Pending` forever. Pre-create hostPath PVs under the **same class name**;
the binder matches them to every claim, no manifest changes:

```bash
for i in 1 2 3 4 5; do
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-gp3-pv${i}
spec:
  capacity:
    storage: 10Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: gp3
  hostPath:
    path: /mnt/local-pv/${i}
    type: DirectoryOrCreate
EOF
done
```

Five 10Gi volumes cover all gp3 claims (mysql 5, ollama 10, prometheus 10,
loki 10, tempo 10 — a 10Gi PV satisfies any claim ≤10Gi). The hostPath lives
inside the kind **node container** — it vanishes with `kind delete cluster`,
which is what you want locally.

### c. TLS certificate (replaces public Let's Encrypt)

The Gateway's HTTPS listener hostname is hardcoded to
`52.43.97.152.nip.io` (`k8s/gateway.yml`). Point it at the MetalLB IP the
gateway gets in Step 6, and give the listener a self-signed cert —
cert-manager's ACME Certificate will just sit `Failed` locally (it can't be
reached from the internet) and **never touches a Secret it didn't create**:

```bash
# after Step 6 has created namespace 'bankapp':
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -subj "/CN=52.43.97.152.nip.io" \
  -addext "subjectAltName=DNS:52.43.97.152.nip.io,DNS:localhost" \
  -keyout /tmp/bankapp-tls.key -out /tmp/bankapp-tls.crt

kubectl -n bankapp create secret tls bankapp-tls \
  --cert=/tmp/bankapp-tls.crt --key=/tmp/bankapp-tls.key

# map the manifest hostname to the gateway's MetalLB IP (needs sudo):
echo "<GATEWAY_IP> 52.43.97.152.nip.io" | sudo tee -a /etc/hosts
#   <GATEWAY_IP> = output of the address query in Step 6, e.g. 172.18.0.100
```

## Step 6 — the application (GitOps)

`argocd/application.yml` points at the **upstream** repo
(`TrainWithShubham/... @ feat/gitops`). Locally, sync *your* fork's `k8s/`
instead — same project, same sync policy:

```bash
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bankapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Mujakkir-Pathan/AI-BankApp-DevOps.git   # your fork
    targetRevision: main
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: bankapp
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF
```

The fork must be pushed and reachable by ArgoCD (public repo = no credentials
needed). Watch it, grab the gateway IP for the `/etc/hosts` line in Step 5c,
then create the TLS secret if you haven't already:

```bash
kubectl -n argocd get app bankapp -w          # Synced / Healthy
kubectl get pvc -A                            # ALL must be Bound (5b)
kubectl -n bankapp get gateway bankapp-gateway -o jsonpath='{.status.addresses[0].value}'
                                              # -> MetalLB IP, e.g. 172.18.0.100
```

## Step 7 — verify

```bash
curl -sk https://52.43.97.152.nip.io/actuator/health        # {"status":"UP"}
curl -sk -o /dev/null -w "%{http_code}\n" https://52.43.97.152.nip.io/login   # 200
curl -s  -o /dev/null -w "%{http_code}\n" http://52.43.97.152.nip.io/         # 301 -> https

kubectl -n bankapp get hpa              # 4 replicas -> scaled (metrics-server)
kubectl -n bankapp get pods             # bankapp, mysql, ollama Running
```

The Ollama pod's `postStart` hook pulls `tinyllama` automatically
(readinessProbe waits for it — first start downloads ~1GB). Fallback:

```bash
kubectl -n bankapp exec deploy/ollama -- ollama pull tinyllama
```

> Self-signed cert: browsers warn — that's expected. Access is by
> `52.43.97.152.nip.io` because the HTTPS listener only matches that hostname
> (the `/etc/hosts` line from Step 5c).

## Step 8 — observability + ArgoCD UIs

```bash
# Grafana — admin / bankapp (gitops/observability/grafana-values.yaml)
kubectl -n observability port-forward svc/observability-grafana 3000:80
#   dashboards: "BankApp" (RED) + Ollama health — via observability-dashboards app
#   alerts: gitops/observability/manifests/prometheusrule-bankapp.yaml (6 rules;
#   Alertmanager routing off by default in prometheus-values.yaml)

# Prometheus UI (service created by prometheus-operator)
kubectl -n observability port-forward svc/prometheus-operated 9090:9090

# ArgoCD UI — https://localhost:8080, admin / <Step 3 password>
kubectl -n argocd port-forward svc/argocd-server 8080:443

kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

Traces: Envoy Gateway → OTel gateway collector → Tempo (+ span metrics →
Prometheus). Logs: agent DaemonSet → collector → Loki. Same telemetry path
as EKS, see [`gitops/README.md`](gitops/README.md).

## Day-2 / dev loop

Identical GitOps loop as EKS: **edit → push → ArgoCD syncs** (automated,
prune + self-heal). Local `kubectl edit`s of synced objects get reverted —
that's exactly why the three substitutes in Step 5 are *separate* objects
with no git counterpart.

Trying your own code: build and push an image (DockerHub), then bump the tag
in `k8s/bankapp-deployment.yml` and push — CI (`docker-push` +
`gitops-bump`) does this automatically on GitHub. The manifest currently
references the public `trainwithshubham/ai-bankapp-eks:1c7cb0e`. For a quick
no-CI experiment you can `docker build -t <tag> . && kind load docker-image
<tag>` instead of pushing — but the manifest says `imagePullPolicy: Always`,
so the tag has to exist in a registry unless you also switch that policy.

## Teardown

```bash
kubectl delete application bankapp -n argocd --ignore-not-found   # app first (prune)
for f in external-secrets cert-manager observability-prometheus observability-loki \
         observability-tempo observability-collector-gateway observability-collector-agent \
         observability-grafana observability-config observability-dashboards; do
  kubectl delete application "$f" -n argocd --ignore-not-found
done                                          # CRD-carrying apps (ESO, cert-manager) last

kind delete cluster                           # takes MetalLB, PVs, node data with it
# then remove the /etc/hosts line you added for 52.43.97.152.nip.io
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| envoy svc EXTERNAL-IP `<pending>` | MetalLB missing or pool outside the docker network — `kubectl -n metallb-system get pods`, recheck `docker network inspect kind` subnet vs pool range |
| Gateway has no address | MetalLB up + pool applied; `kubectl -n bankapp get gateway bankapp-gateway` |
| Pool applied but no IP allocated | webhook not ready yet — wait for `metallb-webhook` pod, re-apply the pool |
| PVCs `Pending` | Step 5b missing/misspelled — `kubectl get pv`, storageClassName must be exactly `gp3` |
| 404 / connection refused on HTTPS | `/etc/hosts` line missing or stale (IP changed) — Host must be `52.43.97.152.nip.io` → current gateway IP |
| Browser "not secure" | expected — self-signed cert (5c) |
| Certificate object `Failed` | expected locally (ACME unreachable); harmless |
| Docker OOM-killed / pods `Pending` (`Insufficient memory`) | kind caps nothing itself — raise Docker's memory to ≥10 GB and `kind delete cluster` + recreate |
| `bankapp-secret` missing, ExternalSecret error | ESO not ready (Step 4) or fake store not applied (5a): `kubectl get clustersecretstore aws-secrets-manager` |
| `ExternalSecret` says store not found | apply 5a **before** Step 6, or ArgoCD will keep the app red until you do |
| App image pull errors | image is public on DockerHub; building your own? push a tag + update `k8s/bankapp-deployment.yml` |
| `OutOfSync` on config apps right after apply | transient (GatewayClass/CRD ordering) — ArgoCD retries; check `kubectl -n argocd get applications` |
| HPA shows `<unknown>` targets | metrics-server patch missing (Step 1) — `kubectl -n kube-system get deploy metrics-server` |
