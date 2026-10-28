# Deployment Playbook — AI BankApp on EKS (end-to-end)

Everything from a bare laptop to a running EKS cluster: **Terraform** (state, VPC,
EKS, ArgoCD, Secrets Manager) → **GitOps** (ArgoCD app-of-apps for the platform)
→ **Helm** (Envoy Gateway, observability) → **raw manifests** (the app).

- Running **the same stack locally, no AWS**: [`deploy-local.md`](deploy-local.md)
- Per-stack deep dives: [`gitops/README.md`](gitops/README.md),
  [`terraform/bootstrap/README.md`](terraform/bootstrap/README.md),
  [`ansible/README.md`](ansible/README.md)

## What gets deployed

| Layer | Tool | Source of truth |
|-------|------|-----------------|
| S3 state bucket | Terraform | `terraform/bootstrap/` (local state) |
| VPC + EKS + ArgoCD + Secrets Manager secret | Terraform | `terraform/` (S3 state) |
| ESO, cert-manager, Prometheus/Loki/Tempo/Grafana, OTel collectors, dashboards | ArgoCD app-of-apps | `gitops/argocd/platform.yaml` (waves 0-4) |
| Envoy Gateway (Gateway API) + extension CRDs | Helm | `scripts/deploy.sh` (idempotent) |
| BankApp + MySQL + Ollama, Gateway, TLS, HPA, RBAC | ArgoCD (raw manifests) | `argocd/application.yml` → `k8s/` |
| Image build, quality/security gates, tag bump | GitHub Actions | `.github/workflows/` |

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| AWS CLI v2 | any | `aws configure` with EKS/VPC/IAM/S3/SecretsManager perms |
| Terraform | >= 1.11 | S3 state locking needs it (`use_lockfile`) |
| kubectl | any | |
| Helm | 3.x | |
| jq, git, openssl | any | `deploy.sh` preflight checks these |

GitHub repo secrets (CI pushes images and bumps tags):

- `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`
- optional: `SONAR_TOKEN` (sonar-scan stays soft without it)

No EC2 box? You can run all of this from your laptop. Want a dedicated
deployment machine instead — provision an Ubuntu EC2 and set it up with the
Ansible playbooks: [`ansible/README.md`](ansible/README.md).

---

## Step 0 — Bootstrap remote state (one-time, local state)

The main Terraform config keeps its state in S3. Bucket names are globally
unique, so the bucket is its own tiny layer:

```bash
cd terraform/bootstrap
terraform init
terraform apply
terraform output -raw backend_hcl > ../backend.hcl   # gitignored, account-specific
cd ..
```

## Step 1 — Provision the infrastructure (~15 min)

```bash
cd terraform
terraform init          # picks up backend.hcl; offers to migrate local state
terraform plan
terraform apply
```

Creates: VPC (3 AZs), EKS cluster (3x `m7i-flex.large`, autoscales to 5),
ArgoCD, the `bankapp/mysql` Secrets Manager secret, EBS CSI IRSA. Tune via
`terraform/terraform.tfvars` (region, node type/count).

## Step 2 — Point kubectl at the cluster

```bash
terraform output -raw configure_kubectl | bash
kubectl get nodes        # 3 nodes, Ready
```

Grab the ArgoCD admin password now:

```bash
terraform output -raw argocd_initial_password | bash   # base64-decodes it
# login: admin / <password>   (UI: kubectl -n argocd port-forward svc/argocd-server 8080:443)
```

## Step 3 — Give the app its database password

The plaintext `k8s/secrets.yml` is gone; the app now reads a Kubernetes Secret
built by External Secrets Operator from AWS Secrets Manager. Create the value
once (generates a random password):

```bash
terraform output -raw set_bankapp_secret | bash
```

> **Ordering matters** — if the `bankapp` app syncs before this secret has a
> value, pods stay `ContainerCreating`. Step 4's preflight refuses to continue
> until the secret exists.

## Step 4 — Deploy everything

```bash
./scripts/deploy.sh
```

The script is idempotent and does, in order:

1. **Preflight** — kubeconfig, nodes, current branch pushed to `origin`,
   `bankapp/mysql` secret has a value.
2. **Gateway API CRDs** (`kubectl apply --server-side`) + **Envoy Gateway**
   (Helm, `--skip-crds`) + its extension CRDs from the chart's `crds/generated/`.
3. **Platform** — applies `gitops/argocd/platform.yaml`; ArgoCD then installs
   (by wave): External Secrets Operator → ClusterSecretStore → cert-manager →
   staging ClusterIssuer → kube-prometheus-stack / Loki / Tempo / Grafana /
   OTel collectors → ServiceMonitors + PrometheusRule + EnvoyProxy telemetry
   + dashboards ConfigMaps.
4. **The app** — applies `argocd/application.yml`; ArgoCD syncs `k8s/` into
   namespace `bankapp` (deployments, MySQL PVC, Gateway/HTTPRoute TLS,
   HPA, ExternalSecret, intern RBAC).
5. **Verify + print the public URL.**

Doing it by hand instead:

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.2.6 \
  -n envoy-gateway-system --create-namespace --skip-crds --wait
helm pull oci://docker.io/envoyproxy/gateway-helm --version v1.2.6 --untar -d /tmp/eg-chart
kubectl apply --server-side -f /tmp/eg-chart/gateway-helm/crds/generated/
kubectl -n envoy-gateway-system rollout restart deploy/envoy-gateway

kubectl apply -f gitops/argocd/platform.yaml    # platform, waves 0-4
kubectl apply -f argocd/application.yml         # the app
```

## Step 5 — Verify

```bash
# public URL (Envoy Gateway NLB)
kubectl -n bankapp get gateway bankapp-gateway -o jsonpath='{.status.addresses[0].value}'

curl -s https://<ADDR>/actuator/health           # {"status":"UP"}
curl -s -o /dev/null -w "%{http_code}\n" -L https://<ADDR>/login   # 200

kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
kubectl get pvc -A                              # all Bound
```

Observability (installed by the platform, not manually):

```bash
kubectl -n observability port-forward svc/observability-grafana 3000:80
# admin / bankapp  (gitops/observability/grafana-values.yaml)
# dashboards: "BankApp" folder (RED) + Ollama health — arrive via
# the observability-dashboards app as ConfigMaps
# alerts: gitops/observability/manifests/prometheusrule-bankapp.yaml
# (6 rules; Alertmanager routing is off by default — enable it in
# gitops/observability/prometheus-values.yaml)
```

AI chatbot — Ollama starts empty, pull the model once:

```bash
kubectl -n bankapp exec deploy/ollama -- ollama pull tinyllama
```

TLS: the platform ships the **staging** ClusterIssuer (`gitops/cert-manager/`).
The production Let's Encrypt issuer and HTTPS listener live in
`k8s/cert-manager.yml` + `k8s/gateway.yml` (synced by the app). Point your
domain's CNAME at the NLB hostname before expecting a real cert.

---

## CI/CD after the first deploy

```
push → devsecops.yml (gates) → docker-push.yml (image @ commit SHA)
     → gitops-bump.yml (k8s/bankapp-deployment.yml + helm values tag)
     → ArgoCD auto-sync (self-heal + prune) → rolling update
```

- **Gates (hard, block the pipeline):** Checkstyle + yamllint, tests with
  MySQL service, GitLeaks, hadolint, image build.
- **Gates (soft, `continue-on-error`):** trivy image, OWASP dependency-check,
  Sonar, Terraform security scans.
- **Manual:** `dast.yml` (ZAP baseline) via workflow_dispatch.
- `terraform-ci.yml` runs on every `terraform/` change.

> **Fork/branch note:** `argocd/application.yml` still points at the upstream
> repo (`TrainWithShubham/...` @ `feat/gitops`). Everything under `gitops/`
> points at `Mujakkir-Pathan/...` @ `main`. If you deploy from your own fork
> or branch, edit `repoURL`/`targetRevision` in both places — ArgoCD can only
> sync what it can fetch (the `deploy.sh` preflight checks this).

---

## Cleanup — order matters

Helm/ArgoCD-created Load Balancers and Security Groups live **outside**
Terraform. Destroy the cluster first and they orphan, blocking VPC deletion.

```bash
# 1. the app (deletes Gateway -> NLB goes away)
kubectl -n argocd delete app bankapp --ignore-not-found

# 2. the platform (children prune themselves; CRD apps last)
kubectl -n argocd delete app platform --ignore-not-found

# 3. Envoy Gateway (creates the NLB controller side)
helm uninstall eg -n envoy-gateway-system

# 4. wait for LBs to terminate
sleep 60
aws elb describe-load-balancers --region us-west-2 \
  --query 'LoadBalancerDescriptions[*].LoadBalancerName' --output text   # should be empty

# 5. now the cluster can go
cd terraform && terraform destroy

# 6. state bucket last (destroying it earlier loses the cluster inventory)
cd bootstrap && terraform destroy
```

**If `terraform destroy` sticks on VPC delete** (`DependencyViolation`),
find and delete the orphaned security groups / ENIs for the VPC, delete the
VPC manually, then re-run `terraform destroy` to reconcile state.

---

## Gotchas we hit

1. **Gateway API CRDs + Envoy Gateway conflict** — `kubectl apply` is
   client-side; the chart then fights it for CRD ownership. Always
   `--server-side` for CRDs + `--skip-crds` on the Helm install.
2. **`--skip-crds` skips Envoy Gateway's own CRDs too** — BackendTrafficPolicy
   etc. fail with `no matches for kind` until you apply the chart's
   `crds/generated/` (the script does this; see Step 4 manual block).
3. **Two Prometheus operators fight over CRDs** — the old manual
   `kube-prometheus` release in `monitoring` vs the platform's
   `observability-prometheus` in `observability`. Pick one:
   `helm uninstall kube-prometheus -n monitoring`. `deploy.sh` warns if it
   detects the manual one.
4. **Secrets before the app** — `k8s/external-secret.yml` resolves nothing
   until Step 3's value exists in Secrets Manager; pods hang otherwise.
5. **Apple Silicon builds** — EKS nodes are amd64. Local pushes must be
   `docker buildx build --platform linux/amd64 --push`. CI is unaffected
   (runs on ubuntu/amd64).
6. **First deploy has no image yet** — CI pushes the first tag; if ArgoCD
   applies before that, pods show `ImagePullBackOff` until the first
   `docker-push` run finishes.
7. **Login redirect loop with >1 replica** — Envoy Gateway bypasses
   `sessionAffinity` and load-balances per-request, so in-memory sessions +
   CSRF break. `k8s/gateway.yml` pins sessions via `BackendTrafficPolicy`
   cookie hashing; keep `SERVER_FORWARD_HEADERS_STRATEGY=native`.
8. **`kubectl rollout restart` shows OutOfSync** — the restart annotation
   isn't in Git. Harmless; the next image bump realigns it.
9. **HTTP→HTTPS** — `k8s/httproute-redirect.yml` 301s port 80; the ACME
   challenge route (Exact path) still works for cert-manager.

## Access summary

| Service | How to reach | Credentials |
|---------|--------------|-------------|
| BankApp | `https://` + gateway address (Step 5) | app login |
| ArgoCD | port-forward `svc/argocd-server 8080:443` | `admin` / Step 2 |
| Grafana | port-forward `svc/observability-grafana 3000:80` | `admin` / `bankapp` |
| MySQL / Ollama | not exposed publicly (ClusterIP) | kubectl exec only |
