# GitOps layer (app-of-apps)

This directory is the **platform** half of the GitOps setup: operators and
observability, installed as ArgoCD Applications instead of one-off
`helm install` commands. The application itself still syncs from `k8s/` via
`argocd/application.yml` (the `bankapp` Application).

```
gitops/
  argocd/
    platform.yaml                 <- apply THIS to install everything below
    platform/
      external-secrets.yaml       wave 0  ESO operator (CRDs)
      external-secrets-config.yaml wave 1  ClusterSecretStore
      cert-manager.yaml           wave 0  cert-manager operator (adopts a
                                          manual install if present)
      cert-manager-config.yaml    wave 1  letsencrypt-staging issuer
      observability-prometheus.yaml wave 1 kube-prometheus-stack (ns observability)
      observability-loki.yaml     wave 1  logs
      observability-tempo.yaml    wave 1  traces
      observability-collector-gateway.yaml wave 2
      observability-collector-agent.yaml   wave 2
      observability-grafana.yaml  wave 3
      observability-config.yaml   wave 4  ServiceMonitors, PrometheusRule, EnvoyProxy
      observability-dashboards.yaml wave 4 dashboards-as-ConfigMaps chart
  external-secrets/
    cluster-secret-store.yaml     aws-secrets-manager store (pod identity auth)
  cert-manager/
    clusterissuers.yaml           staging issuer (prod stays in k8s/cert-manager.yml)
  observability/
    *-values.yaml                 helm values for every chart above
    manifests/                    ServiceMonitors, PrometheusRule, EnvoyProxy telemetry
    dashboards/                   Grafana dashboard JSON + ConfigMap chart
```

## Quick start

```bash
# 0. one-time infra (S3 state + cluster + Secrets Manager secret)
cd terraform && terraform init && terraform apply
terraform output -raw set_bankapp_secret | bash     # sets bankapp/mysql
cd ..

# 1. everything (preflight, Gateway API, Envoy Gateway, platform, app)
./scripts/deploy.sh
```

Or by hand:

```bash
kubectl apply -n argocd -f gitops/argocd/platform.yaml   # platform (waves 0-4)
kubectl apply -f argocd/application.yml                  # the app (k8s/)
```

## Important sequencing rules

1. **Secrets first.** `k8s/secrets.yml` (plaintext) was replaced by
   `k8s/external-secret.yml`. If `bankapp/mysql` has no value when the
   `bankapp` app syncs, pods will not start:
   `cd terraform && terraform output -raw set_bankapp_secret | bash`.
2. **ESO before the app.** Apply `platform.yaml` (wave 0 installs the CRDs)
   and wait for `external-secrets` to be Ready before the `bankapp` app syncs
   `k8s/external-secret.yml`, or its apply fails until the CRD exists
   (ArgoCD retries automatically).
3. **Pick ONE observability path.** A manual `kube-prometheus` release in
   `monitoring` (the old pre-GitOps way) clashes with the platform's
   `observability-prometheus` in `observability`. Running both = two
   Prometheus operators fighting over CRDs:
   `helm uninstall kube-prometheus -n monitoring` first.
4. **repoURL / targetRevision.** Everything under `gitops/` points at
   `https://github.com/Mujakkir-Pathan/AI-BankApp-DevOps.git` @ `main`.
   If you push to a different fork or branch, edit those fields (including
   `argocd/application.yml`, which still points at the upstream
   `feat/gitops` branch).

## Telemetry path

```
Envoy Gateway ──traces+access logs──▶ OTel collector (gateway)
container logs ──agent (daemonset)──▶ OTel collector ──▶ Loki (logs)
                                         │
                                         ├──▶ Tempo (traces)
                                         └──▶ span_metrics ──▶ Prometheus
bankapp /actuator/prometheus ◀── ServiceMonitor ──┘
```

- Dashboards: port-forward Grafana
  (`kubectl -n observability port-forward svc/observability-grafana 3000:80`,
  admin/bankapp) — BankApp RED + Ollama health arrive via the
  `observability-dashboards` app.
- Alerts: `gitops/observability/manifests/prometheusrule-bankapp.yaml`
  (evaluated by Prometheus; Alertmanager is disabled in
  `prometheus-values.yaml` — enable it there to route notifications).

## Rollback

Each child Application can be deleted independently
(`kubectl -n argocd delete app <name>`, prune removes its resources), or
delete the whole layer:

```bash
kubectl -n argocd delete app platform --ignore-not-found
# children prune themselves via automated prune; CRD-carrying apps
# (external-secrets, cert-manager) should be deleted LAST so wave-1
# config resources disappear before their CRDs
```
