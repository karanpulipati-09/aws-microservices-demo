## aws-microservices-demo

Production-grade AWS infrastructure portfolio project built by **[Karan Pulipati](https://www.linkedin.com/in/karan-pulipati)**.  
Demonstrates Terraform, EKS, Helm, and fully automated CI/CD from code push to live deployment.

> This repository intentionally uses a hybrid AWS topology: a private EC2 + ALB + RDS foundation for ingress and data access, layered with an EKS cluster for containerized workloads, Helm deployment, autoscaling, and GitOps-style delivery. The architecture is designed to be explicit, not contradictory.

## Architecture

```
Internet
    ↓ HTTPS (self-signed cert on the ingress ELB)
ingress-nginx  ← single ELB entry point
    ├── /api/* → api service (ClusterIP :3000)
    └── /*     → frontend service (ClusterIP :80 → pod :8080)

EKS Cluster (private subnets — t3.small nodes, v1.32, Cluster Autoscaler 1→5)
    ├── frontend pods   ← nginx-unprivileged serving the task UI (HPA 2–5)
    ├── api pods        ← Node.js tasks API (HPA 2–5) ──► RDS MySQL (port 3306)
    ├── ArgoCD          ← installed by Terraform; watches this repo (GitOps)
    ├── External Secrets Operator ← syncs AWS Secrets Manager → Kubernetes Secret (IRSA)
    ├── metrics-server  ← CPU/memory metrics for HPA
    ├── Prometheus + Grafana ← kube-prometheus-stack; "Tasks API Overview" dashboard
    └── Cluster Autoscaler ← adds nodes when pods are Pending

ECR (frontend, api)  ← images tagged with the short git SHA

ALB  (public subnets) → EC2 (private, nginx) → RDS   ← the classic 3-tier foundation
RDS  (DB subnets)    ← MySQL 8.0, isolated, encrypted, reachable from EC2 and EKS nodes only

EC2/nodes → NAT Gateway → Internet (package installs, image pulls)
Secrets: random_password → Secrets Manager (JSON: host, port, user, password, dbname)
         → External Secrets Operator → Secret "api-db" → API pod env vars (never in Git)
```

### The application
A small **tasks API** (`/api/tasks`: create, list, update, delete) backed by RDS MySQL, with a task-list UI in the frontend. A migration Job creates the schema on every sync, before the API rolls out.

## Infrastructure

| Resource | Purpose |
|---|---|
| VPC | Isolated private network — 3 subnet tiers across 2 AZs |
| Internet Gateway | Public internet access for ALB |
| NAT Gateway | Outbound-only internet for private EC2 + EKS nodes |
| ALB | Internet-facing load balancer in public subnets (HTTP + optional HTTPS) |
| EC2 | App server running nginx in private subnet |
| RDS MySQL 8.0 | Database in isolated DB subnet, encrypted at rest, 1-day backup retention (free tier compliant) |
| Secrets Manager | Auto-generated DB password stored securely |
| EKS Cluster | Kubernetes cluster in private subnets (v1.32) |
| EKS Node Group | t3.small worker nodes (min 1, max 5); the Cluster Autoscaler owns the node count (`desired_size` is ignored in Terraform) |
| EKS OIDC Provider | Enables IRSA — pods assume IAM roles via service accounts |
| EBS CSI Driver | EKS addon for EBS-backed PersistentVolumes (IRSA-secured) |
| gp3 StorageClass | Default storage class for PVCs — faster and cheaper than gp2 |
| ingress-nginx | Helm-managed nginx ingress controller — single ELB entry point |
| RBAC | `dev-admin` + `dev-readonly` roles in `dev` namespace |
| HPA | Horizontal Pod Autoscaler on frontend + api (min 2, max 5, CPU target 70%) |
| metrics-server | Provides CPU/memory metrics for HPA |
| Cluster Autoscaler | Scales the node group (1→5) based on Pending pods (IRSA-secured) |
| kube-prometheus-stack | Prometheus + Grafana — cluster-wide observability |
| ECR | Private container registry — `frontend` + `api` repos |
| ArgoCD | GitOps controller, installed by Terraform; the `api` and `frontend` Applications are also created by Terraform (`argocd-apps` chart) |
| External Secrets Operator | Syncs the app DB credentials from Secrets Manager into a Kubernetes Secret via an IRSA role scoped to that one secret |
| App DB secret | `demo-dev-app-db` — JSON with host, port, username, password, dbname |
| S3 | Terraform remote state with native S3 locking (`use_lockfile`) |
| CloudWatch Alarms | ALB 5xx, RDS replica lag, sent via SNS |
| CloudTrail | Audit logging for S3 data events on state bucket |
| EventBridge | Routes state bucket events to SNS topic |

## Security

- EC2 in **private subnet** — not directly reachable from internet
- EC2 SG allows port 80 **only from ALB SG**
- RDS SG allows port 3306 **only from the EC2 SG and the EKS cluster SG** (one inline rule; see Issues in ARCHITECTURE.md)
- DB subnet has **no internet route** — RDS completely isolated
- DB password **auto-generated** by Terraform, stored in Secrets Manager
- App credentials reach pods through **External Secrets (IRSA, read-only on one secret)** — nothing sensitive in Git or Helm values
- Pods run **non-root** (`runAsNonRoot`, seccomp `RuntimeDefault`, all capabilities dropped, no privilege escalation) with a PodDisruptionBudget per service
- NetworkPolicy manifests exist in `k8s/` but are **not enforced** until the VPC CNI network policy agent is enabled
- `publicly_accessible = false` on RDS — double protection
- EKS nodes in **private subnets** — only reachable via kubectl through IAM
- No SSH keys — access via AWS Systems Manager (SSM) if needed
- ECR repos have `scan_on_push = true` — Trivy scans on every CI build
- GHA IAM role uses **OIDC** — no long-lived AWS credentials stored in GitHub
- RBAC — `dev-readonly` (get/list/watch only) + `dev-admin` (full access) in `dev` namespace
- EBS CSI IRSA — addon IAM role scoped to `kube-system:ebs-csi-controller-sa` only
- Terraform PR pipeline runs **gitleaks** (secrets scan) + **tfsec** (misconfiguration scan) on every PR
- Cluster Autoscaler IRSA — IAM role scoped to `kube-system:cluster-autoscaler` SA only
- Grafana admin password auto-generated by Terraform (`random_password`), never hardcoded
- RDS encryption at rest using AWS-managed KMS key (free)
- Optional ALB HTTPS listener (set `certificate_arn` to enable) with TLS 1.2+
- HSTS + CSP security headers on ingress (force HTTPS, restrict script sources)
- CloudTrail auditing all S3 data events on Terraform state bucket
- SNS topic for CloudWatch alarm notifications (subscribe with `alert_email` variable)
- ALB 5xx error alarm + RDS replica lag alarm
- PodSecurity `restricted` baseline + default-deny NetworkPolicy in `dev` namespace
- tflint + tfsec + checkov in CI — fails PR on lint/security errors

## Modules

| Module | What it creates |
|---|---|
| `modules/vpc` | VPC, subnets, IGW, NAT gateway, route tables |
| `modules/ec2` | EC2 instance with nginx, AMI auto-detected |
| `modules/alb` | ALB, target group, listener, HTTPS listener (optional), target group attachment |
| `modules/rds` | RDS MySQL, DB subnet group, RDS security group |
| `modules/eks` | EKS cluster, node group, IAM roles, access entries, OIDC provider, EBS CSI IRSA + addon, Cluster Autoscaler IRSA |
| `modules/ecr` | ECR repos with lifecycle policy (keep last 5 images) |

## Kubernetes + Helm

Charts in `helm/`, deployed by **ArgoCD** (automated sync, prune, self-heal):

| Chart | Service | Replicas | Also contains |
|---|---|---|---|
| `helm/frontend` | ClusterIP 80 → pod 8080 | HPA: 2–5 (CPU 70%) | Ingress, PDB |
| `helm/api` | ClusterIP 3000 | HPA: 2–5 (CPU 70%) | SecretStore + ExternalSecret, migration Job, ServiceMonitor, Grafana dashboard ConfigMap, PDB |

**Sync order (API)** via ArgoCD sync waves: SecretStore (-2) → ExternalSecret (-1) → migration Job (0, Sync hook) → Deployment (1). The Job needs the Secret; the Deployment needs the schema.

**HPA behaviour**: the `replicas` field is omitted from the Deployment when the HPA is enabled, so the HPA owns the replica count and neither `helm upgrade` nor ArgoCD self-heal fights it.

**Cluster Autoscaler**: watches for Pending pods (nodes full, a t3.small fits ~11 pods) → calls the AWS ASG API → a new node joins in ~2 min. Scales down after ~10 min of underutilization.

**Monitoring** (`kube-prometheus-stack`): the API exposes `/metrics` (prom-client); a `ServiceMonitor` makes Prometheus scrape it, and the **Tasks API Overview** dashboard (12 panels) loads automatically through the Grafana sidecar (ConfigMap label `grafana_dashboard=1`).
```bash
aws eks update-kubeconfig --region us-east-1 --name demo-dev-eks

# Grafana password, then port-forward (UI at http://localhost:3000, dashboard uid: api-overview)
terraform -chdir=terraform output -raw grafana_admin_password
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80

# ArgoCD UI at https://localhost:8080
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

**Ingress** (ingress-nginx) routes everything through one ELB: `/api/*` → api, everything else → frontend. The ELB serves a self-signed certificate (browser warning); production would use a domain with cert-manager or ACM.

**Per-environment values** live next to each chart (`values-dev.yaml`, `values-staging.yaml`, `values-prod.yaml`). Only `dev` is deployed today.

## Applications

| App | Source | ECR Repo | Container port |
|---|---|---|---|
| frontend | `apps/frontend/` | `frontend` | 8080 (nginx-unprivileged) |
| api | `apps/api/` | `api` | 3000 (Node.js 20, Express, mysql2, prom-client) |

API endpoints:

| Endpoint | Purpose |
|---|---|
| `GET /api/health` | Liveness — no database call, returns `{ status, env, version, sha, deployedBy }` |
| `GET /api/ready` | Readiness — checks the database (503 if unreachable) |
| `GET /api/tasks`, `POST /api/tasks` | List / create tasks |
| `PATCH /api/tasks/:id`, `DELETE /api/tasks/:id` | Mark done / delete |
| `GET /metrics` | Prometheus metrics (request duration histogram + Node.js defaults) |

Images are tagged with the short git SHA (7 chars). No `latest` tag.

## CI/CD

GitOps: CI builds the image, CD records the new tag **in Git**, ArgoCD pulls the change into the cluster. No pipeline runs `helm upgrade` against the cluster.

```
apps/** push ─► CI — Build and Push   (build both images, Trivy scan, push to ECR, tag = short SHA)
                    │ workflow_run (success)
                    ▼
                CD — Deploy to Dev     (bumps the tag in helm/*/values.yaml, commits to main [skip ci])
                    │
                    ▼
                ArgoCD sees the Git change and syncs the cluster

terraform/** PR ─────► Terraform Plan
terraform/** push ───► Terraform Apply ─(workflow_run)─► CI ─► CD ─► ArgoCD
```

| Workflow | Trigger | What it does |
|---|---|---|
| `build-push.yml` (CI) | Push to `main` on `apps/**`, after a successful Terraform Apply, or manual | Builds frontend + api in parallel, Trivy scan, pushes to ECR |
| `deploy.yml` (CD) | `workflow_run` on CI success, or manual | Updates the image tag in the Helm values and pushes the commit |
| `terraform-plan.yml` | Pull request touching `terraform/**` | gitleaks, tflint, tfsec, Checkov, Infracost, `terraform plan` posted on the PR |
| `terraform-apply.yml` | Push to `main` on `terraform/**`, or manual | `terraform apply -auto-approve` (no approval gate yet) |
| `terraform-destroy.yml` | Manual (`workflow_dispatch`) | Destroys all resources from the Actions UI |

**CI after Apply**: CI also runs when Terraform Apply succeeds, so the ECR repositories exist before the first image push on a fresh stack.

**Authentication**: OIDC — no AWS access keys stored in GitHub.

**Bootstrap separation**: the OIDC provider and IAM role live in `bootstrap/` with a separate Terraform state, so destroying the main stack never touches them.

**Image tagging**: short 7-char git SHA only, so each deployment is pinned to an exact commit (easy rollback).

## Terraform State

| State file | Contains |
|---|---|
| `bootstrap/terraform.tfstate` | OIDC provider + GHA IAM role — **never destroyed** |
| `terraform/terraform.tfstate` | All infra (VPC, EKS, ECR, RDS, etc.) — freely destroyable |

## Rebuild and teardown

**Rebuild** (about 15–20 minutes): run *Terraform Apply* (merge a change under `terraform/` or use *Run workflow*). Terraform creates the network, EKS, RDS, ECR, ArgoCD and the ArgoCD Applications. CI then builds and pushes the images, CD bumps the tag, and ArgoCD syncs. No manual `kubectl` step is needed.

**Teardown**: run the *Terraform Destroy* workflow. Known issue: the External Secrets controller can be removed before the `ExternalSecret` it manages, and the object's finalizer then blocks the uninstall until Helm times out. Workaround: `kubectl patch externalsecret api-api-db -n dev --type=merge -p '{"metadata":{"finalizers":null}}'`, force-delete the pods in `external-secrets`, then re-run the destroy.

**Cost**: a running stack burned roughly **$0.50/hour** of credits in practice (EKS control plane, 3–4 t3.small nodes, NAT gateway, RDS, load balancer, plus data transfer). Destroy it after each session.

