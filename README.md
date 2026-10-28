<div align="center">

# AI BankApp

### End-to-End GitOps on Amazon EKS

A modern banking application with an integrated AI chatbot, deployed on AWS EKS using Terraform, ArgoCD, Gateway API, and Prometheus monitoring.

[![Java](https://img.shields.io/badge/Java-21-ED8B00?logo=openjdk&logoColor=white)](https://www.oracle.com/java/technologies/javase/jdk21-archive-downloads.html)
[![Spring Boot](https://img.shields.io/badge/Spring%20Boot-3.4.1-6DB33F?logo=springboot&logoColor=white)](https://spring.io/projects/spring-boot)
[![Kubernetes](https://img.shields.io/badge/EKS-1.35-326CE5?logo=kubernetes&logoColor=white)](https://aws.amazon.com/eks/)
[![ArgoCD](https://img.shields.io/badge/ArgoCD-GitOps-EF7B4D?logo=argo&logoColor=white)](https://argo-cd.readthedocs.io/)
[![Terraform](https://img.shields.io/badge/Terraform-IaC-844FBA?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![Docker](https://img.shields.io/badge/Docker-Hub-2496ED?logo=docker&logoColor=white)](https://hub.docker.com/)

---

![Dashboard](screenshots/dashboard.png)

![AI Chatbot](screenshots/ai-chatbot.png)

</div>

---

## Features

- **Banking Operations** — Deposit, withdraw, transfer funds between accounts
- **AI Chatbot** — Context-aware financial assistant powered by Ollama (TinyLlama), self-hosted on Kubernetes
- **Dark/Light Mode** — Glassmorphism UI with theme toggle and localStorage persistence
- **Spring Security** — BCrypt password hashing, CSRF protection, form-based authentication
- **Prometheus Metrics** — Built-in `/actuator/prometheus` endpoint for monitoring

---

## Architecture

<div align="center">

![GitOps Pipeline](screenshots/gitops-pipeline.gif)

</div>

| Layer | Tool |
|-------|------|
| **Infrastructure** | Terraform (VPC + EKS + ArgoCD) |
| **CI Pipeline** | GitHub Actions → DockerHub |
| **GitOps / CD** | ArgoCD (auto-sync from `k8s/` manifests) |
| **Ingress** | Gateway API + Envoy Gateway (AWS NLB) |
| **TLS** | cert-manager + Let's Encrypt (auto-provisioned) |
| **Monitoring** | kube-prometheus-stack (Prometheus + Grafana) |
| **AI Chatbot** | Ollama (TinyLlama) on EKS |
| **Storage** | EBS CSI Driver (gp3 dynamic provisioning) |

---

## What Gets Deployed

| Resource | Details |
|----------|---------|
| **EKS Cluster** | Kubernetes 1.35, 3x `t3.medium` across 3 AZs |
| **BankApp** | 2 replicas with HPA (scales to 4), rolling updates |
| **MySQL 8.0** | Persistent EBS volume (gp3) |
| **Ollama AI** | TinyLlama model with persistent storage |
| **Gateway** | HTTPS with Let's Encrypt TLS, session persistence |
| **Monitoring** | Prometheus + Grafana dashboards |
| **ArgoCD** | Auto-sync, self-heal, prune |

---

## Quick Start

> **Local Kubernetes + GitOps (no AWS):** [`deploy-local.md`](deploy-local.md) — kind + ArgoCD + observability
> **Full EKS deployment:** [`Deploy.md`](Deploy.md) — step-by-step + gotchas
> **Just the app on your machine (no Kubernetes):** `make setup && make up`

```bash
# 0. remote state bucket (one-time)
cd terraform/bootstrap && terraform init && terraform apply \
  && terraform output -raw backend_hcl > ../backend.hcl && cd ../..

# 1. provision infrastructure (~15 min)
cd terraform && terraform init && terraform apply && cd ..

# 2. configure kubectl + set the DB secret
terraform output -raw configure_kubectl | bash
terraform output -raw set_bankapp_secret | bash

# 3. Gateway API + Envoy + platform (ESO, cert-manager, observability) + app
./scripts/deploy.sh

# 4. pull the AI model
kubectl -n bankapp exec deploy/ollama -- ollama pull tinyllama
```

---

## CI/CD — GitOps Flow

```
Code Push → GitHub Actions → Build & Push to DockerHub → Update k8s manifest → ArgoCD auto-sync → EKS
```

1. Push code changes to `feat/gitops`
2. **GitHub Actions** builds the app, pushes Docker image to DockerHub with commit SHA tag
3. Workflow updates `k8s/bankapp-deployment.yml` with new image tag and commits back
4. **ArgoCD** detects the manifest change and auto-syncs to EKS
5. **EKS** performs a rolling update with zero downtime

**GitHub Secrets Required:** `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`

---

## Project Structure

```
.
├── terraform/              # Infrastructure as Code (VPC + EKS + ArgoCD)
├── k8s/                    # Kubernetes manifests (ArgoCD watches this)
│   ├── bankapp-deployment.yml
│   ├── mysql-deployment.yml
│   ├── ollama-deployment.yml
│   ├── service.yml
│   ├── gateway.yml         # Gateway API + HTTPS + session persistence
│   ├── cert-manager.yml    # Let's Encrypt ClusterIssuer
│   ├── hpa.yml             # Horizontal Pod Autoscaler
│   └── ...                 # namespace, configmap, secrets, pv, pvc
├── argocd/
│   └── application.yml     # ArgoCD Application
├── .github/workflows/       # devsecops gates, docker-push, gitops-bump
├── gitops/                  # ArgoCD app-of-apps (platform: ESO, cert-manager, observability)
├── ansible/                 # optional: bootstrap a deployment machine (EC2)
├── Makefile                 # local dev: make setup/up/down/smoke/test
├── Deploy.md                # end-to-end EKS deployment playbook
└── deploy-local.md          # local kind cluster + GitOps, no AWS
```

---

## Documentation

| Document | Purpose |
|----------|---------|
| [`Deploy.md`](Deploy.md) | End-to-end EKS deployment + cleanup + gotchas |
| [`deploy-local.md`](deploy-local.md) | Local kind cluster + ArgoCD + observability, zero AWS |
| [`gitops/README.md`](gitops/README.md) | GitOps platform layer (app-of-apps, telemetry) |
| [`terraform/README.md`](terraform/README.md) | Detailed infrastructure setup + troubleshooting |
| [`ansible/README.md`](ansible/README.md) | Bootstrap an Ubuntu deployment machine |

---

## Tech Stack

**Backend:** Java 21, Spring Boot 3.4.1, Spring Security, Thymeleaf, Actuator

**Frontend:** Bootstrap 5, glassmorphism dark/light UI, CSS custom properties

**AI:** Ollama with TinyLlama — self-hosted, zero cost, runs as a Kubernetes pod

**Database:** MySQL 8.0 with EBS gp3 persistent volumes

**DevOps:** Terraform, GitHub Actions, ArgoCD, Envoy Gateway, cert-manager, kube-prometheus-stack

---

<div align="center">

**TrainWithShubham** — Happy Learning

</div>
