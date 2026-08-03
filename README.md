## aws-microservices-demo

Multi-tier AWS infrastructure built with Terraform. Demonstrates production-grade networking, compute, load balancing, database, EKS, ECR, and CI/CD patterns.

## Architecture

```
Internet
    ↓ HTTP port 80
ALB  (public subnets — us-east-1a, us-east-1b)
    ↓ HTTP port 80 (ALB SG → EC2 SG only)
EC2  (private subnet)  ← nginx
    ↓ MySQL port 3306 (EC2 SG → RDS SG only)
RDS  (DB subnet)  ← MySQL 8.0

EKS Cluster (private subnets — 2x t3.small nodes, v1.32)
    ├── Ingress (nginx) ← single ELB entry point
    │       ├── /api/* → api pod (ClusterIP)
    │       └── /*     → frontend pod (ClusterIP)
    ├── frontend pod   ← nginx serving HTML/JS (ECR image)
    ├── api pod        ← Node.js REST API (ECR image)
    └── postgres pod   ← PostgreSQL 18 (Bitnami chart, no persistence)

ECR (Elastic Container Registry)
    ├── frontend  ← nginx:alpine image
    └── api       ← Node.js REST API

EC2/EKS outbound:
EC2/nodes → NAT Gateway → Internet (package installs, image pulls)

Password flow:
random_password → Secrets Manager → RDS (never hardcoded)
```

## Infrastructure

| Resource | Purpose |
|---|---|
| VPC | Isolated private network — 3 subnet tiers across 2 AZs |
| Internet Gateway | Public internet access for ALB |
| NAT Gateway | Outbound-only internet for private EC2 + EKS nodes |
| ALB | Internet-facing load balancer in public subnets |
| EC2 | App server running nginx in private subnet |
| RDS MySQL 8.0 | Database in isolated DB subnet, not publicly accessible |
| Secrets Manager | Auto-generated DB password stored securely |
| EKS Cluster | Kubernetes cluster in private subnets (v1.32) |
| EKS Node Group | 2x t3.small worker nodes with Auto Scaling (min 1, max 3) |
| ECR | Private container registry — `frontend` + `api` repos |
| S3 + DynamoDB | Terraform remote state + state locking |

## Security

- EC2 is in a **private subnet** — not directly reachable from internet
- EC2 SG allows port 80 **only from ALB SG**
- RDS SG allows port 3306 **only from EC2 SG**
- DB subnet has **no internet route** — RDS completely isolated
- DB password **auto-generated** by Terraform, stored in Secrets Manager
- `publicly_accessible = false` on RDS — double protection
- EKS nodes in **private subnets** — only reachable via kubectl through IAM
- No SSH keys — access via AWS Systems Manager (SSM) if needed
- ECR repos have `scan_on_push = true` — Trivy also scans on every GHA build

## Modules

| Module | What it creates |
|---|---|
| `modules/vpc` | VPC, subnets, IGW, NAT gateway, route tables |
| `modules/ec2` | EC2 instance with nginx, AMI auto-detected |
| `modules/alb` | ALB, target group, listener, target group attachment |
| `modules/rds` | RDS MySQL, DB subnet group, RDS security group |
| `modules/eks` | EKS cluster, node group, IAM roles for control plane + nodes |
| `modules/ecr` | ECR repos with lifecycle policy (keep last 5 images) |

## Kubernetes + Helm

Charts in `helm/`:

| Chart | Services | Namespaces |
|---|---|---|
| `helm/frontend` | ClusterIP port 80 | dev / staging / prod |
| `helm/api` | ClusterIP port 3000 | dev / staging / prod |
| `bitnami/postgresql` | ClusterIP port 5432 | dev / staging / prod |

**Ingress** (nginx controller) routes all traffic through a single ELB:
- `/*` → frontend service
- `/api/*` → api service

```bash
aws eks update-kubeconfig --region us-east-1 --name demo-dev-eks
helm install frontend ./helm/frontend -n dev
helm install api ./helm/api -n dev
helm install postgres bitnami/postgresql -n dev --set primary.persistence.enabled=false
kubectl get ingress -n dev  # get single ELB URL
```

**Per-environment deploy** (same chart, different values):
```bash
helm install frontend ./helm/frontend -n staging -f helm/frontend/values-staging.yaml
helm install frontend ./helm/frontend -n prod    -f helm/frontend/values-prod.yaml
```

> **Note**: Delete Ingress before destroying infra — `helm uninstall ingress-nginx -n ingress-nginx` — otherwise the ELB will block VPC subnet deletion.

## Applications

| App | Source | ECR Repo | Port |
|---|---|---|---|
| frontend | `apps/frontend/` | `frontend` | 80 |
| api | `apps/api/` | `api` | 3000 |

The API exposes `/health` → `{ status: "ok", env: "dev", version: "1.0.0" }`.

Images are tagged with the short git SHA (7 chars) — e.g. `079356d`. No `latest` tag.

## CI/CD

All infrastructure and image changes go through GitHub Actions — no manual commands needed.

| Workflow | Trigger | What it does |
|---|---|---|
| `terraform-plan.yml` | Pull Request to `main` (terraform/** paths) | Runs terraform plan, posts result as PR comment |
| `terraform-apply.yml` | Merge to `main` (terraform/** paths) | Runs terraform apply automatically |
| `terraform-destroy.yml` | Manual (workflow_dispatch) | Destroys all resources via GitHub UI button |
| `build-push.yml` | Push to `main` (apps/** paths) | Builds frontend + api Docker images in parallel, scans with Trivy, pushes to ECR |

**Authentication**: OIDC — no AWS access keys stored in GitHub. GitHub proves its identity to AWS and assumes an IAM role with temporary credentials.

**Bootstrap separation**: OIDC provider + IAM role live in `bootstrap/` with a separate Terraform state (`bootstrap/terraform.tfstate`). Running `terraform destroy` in `terraform/` never touches them — they survive every infra teardown.

**Image tagging**: Short 7-char git SHA only (e.g. `079356d`). Every deployment is pinned to an exact commit for traceability and easy rollback.

**Provider caching**: `.terraform` directory cached via `actions/cache@v4` keyed on `.terraform.lock.hcl`.

**Terraform version**: 1.15.x

## Terraform State

| State file | Contains |
|---|---|
| `bootstrap/terraform.tfstate` | OIDC provider + GHA IAM role — **never destroyed** |
| `terraform/terraform.tfstate` | All infra (VPC, EKS, ECR, RDS, etc.) — freely destroyable |

## Resources created

| Resource | Count |
|---|---|
| VPC | 1 |
| Internet Gateway | 1 |
| Elastic IP | 1 |
| NAT Gateway | 1 |
| Subnets (public + private + DB) | 6 |
| Route tables + associations | 9 |
| Security groups + rules | 7 |
| EC2 instance | 1 |
| ALB + target group + listener + attachment | 4 |
| Random password + Secrets Manager | 3 |
| RDS DB subnet group + RDS instance | 2 |
| EKS cluster + node group | 2 |
| EKS IAM roles + policy attachments | 5 |
| EKS access entry + policy association | 2 |
| ECR repos + lifecycle policies | 4 |
| OIDC provider + GHA IAM role + policy (bootstrap) | 3 |
| **Total** | **53** |
