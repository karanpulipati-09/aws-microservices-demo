# aws-microservices-demo — Architecture

## Overview

A production-grade AWS architecture combining a classic 3-tier foundation (ALB → EC2 → RDS) with a Kubernetes application tier (EKS + Helm), provisioned entirely via Terraform modules and deployed through a fully automated GitHub Actions CI/CD pipeline using OIDC authentication. This is intentionally a hybrid design: the VPC, ALB, EC2, and RDS provide the private network and data plane, while EKS hosts the containerized workloads, ingress routing, autoscaling, and observability stack.

---

## Infrastructure Diagram

```
Internet
    │
    ▼
[ALB] ← public subnets (us-east-1a, us-east-1b)
    │
    ▼
[EC2 - nginx] ← private subnets (no direct internet access)
    │
    ▼
[RDS MySQL 8.0] ← DB subnets (isolated, no internet)
    │
[Secrets Manager] ← stores DB password (random_password, never hardcoded)

[EKS Cluster] ← private subnets, 2x t3.small worker nodes (autoscales to 3)
    ├── ingress-nginx     ← single ELB entry point, routes /api/* and /*
    ├── frontend          ← nginx (ECR), HPA: 2–5 replicas, CPU target 70%
    ├── api               ← Node.js (ECR), HPA: 2–5 replicas, CPU target 70%
    ├── postgres          ← Bitnami chart, gp3 EBS PVC
    ├── metrics-server    ← provides CPU/memory metrics for HPA
    ├── Prometheus        ← scrapes all workloads
    ├── Grafana           ← dashboards (kube-prometheus-stack)
    └── Cluster Autoscaler ← scales node group 1→3 when pods are Pending

[ECR] ← frontend + api images (tagged by short git SHA, scan_on_push enabled)
[S3 + DynamoDB] ← Terraform remote state + locking
```

---

## VPC Layout (Multi-AZ)

| Subnet Type | AZ-a (us-east-1a) | AZ-b (us-east-1b) | Purpose |
|---|---|---|---|
| Public | 10.0.1.0/24 | 10.0.2.0/24 | ALB, NAT Gateway |
| Private | 10.0.10.0/24 | 10.0.11.0/24 | EC2 + EKS nodes |
| DB | 10.0.20.0/24 | 10.0.21.0/24 | RDS only |

- **NAT Gateway** in public subnet → private subnet EC2/EKS nodes can reach internet (outbound only)
- **Internet Gateway (IGW)** → public subnets have full internet access (inbound + outbound)

---

## Terraform Modules

| Module | Resources | Key Concept |
|---|---|---|
| `vpc` | VPC, subnets, IGW, NAT Gateway, route tables | Multi-AZ, 3 subnet tiers |
| `ec2` | EC2 instance, AMI data source | Private subnet + user_data (nginx) |
| `alb` | ALB, target group, listener | Internet-facing, health checks |
| `rds` | RDS MySQL 8.0, subnet group | db.t3.micro, skip_final_snapshot |
| `eks` | EKS cluster, node group, IAM roles, access entries, OIDC provider, EBS CSI IRSA + addon, Cluster Autoscaler IRSA | API_AND_CONFIG_MAP auth, IRSA pattern |
| `ecr` | ECR repos + lifecycle policy (keep last 5 images) | `scan_on_push = true` |

> **Security groups at root level**: ALB SG and EC2 SG reference each other — circular dependency Terraform can only resolve when both are in the same scope.

---

## IRSA Pattern (IAM Roles for Service Accounts)

IRSA allows a Kubernetes pod to assume an AWS IAM role without any AWS credentials stored in the cluster.

```
Pod's service account → annotated with IAM role ARN
    │
    ▼
EKS OIDC Provider validates the SA's projected token
    │
    ▼
AWS STS grants temporary credentials via AssumeRoleWithWebIdentity
    │
    ▼
Pod gets scoped IAM permissions (e.g. EBS API, ASG API)
```

| IRSA Role | Service Account | Permissions |
|---|---|---|
| `demo-dev-eks-ebs-csi-role` | `kube-system:ebs-csi-controller-sa` | `AmazonEBSCSIDriverPolicy` |
| `demo-dev-eks-cluster-autoscaler-role` | `kube-system:cluster-autoscaler` | ASG Describe/SetDesiredCapacity, EC2 Describe |

**Critical**: trust policy `StringEquals` condition must match the exact SA name. Helm chart default for Cluster Autoscaler is `cluster-autoscaler-aws-cluster-autoscaler` — we override with `rbac.serviceAccount.name = "cluster-autoscaler"` to match.

---

## Kubernetes + Helm

Helm charts in `helm/`:

| Chart | Service | Port | Replicas | Strategy |
|---|---|---|---|---|
| `helm/frontend` | ClusterIP | 80 | HPA: 2–5 (CPU 70%) | RollingUpdate maxSurge:1 maxUnavailable:1 |
| `helm/api` | ClusterIP | 3000 | HPA: 2–5 (CPU 70%) | RollingUpdate maxSurge:1 maxUnavailable:1 |
| `bitnami/postgresql` | ClusterIP | 5432 | 1 | — |

**HPA ownership**: `replicas` field is omitted from Deployment when `hpa.enabled = true` — HPA is sole controller of replica count. Without this, `helm upgrade` resets replicas to the values.yaml default on every deploy.

**Ingress** (ingress-nginx): single ELB entry point
- `/api/*` → api service
- `/*` → frontend service

**Storage**: gp3 StorageClass set as default — faster throughput and lower cost than gp2. Backed by EBS CSI driver via IRSA.

**RBAC** (in `dev` namespace):
- `dev-readonly`: get/list/watch on pods, services, deployments
- `dev-admin`: full access (`*` verbs on all resources)

---

## Autoscaling

### Horizontal Pod Autoscaler (HPA)
- Reads CPU metrics from metrics-server every 15s
- Scales up immediately when CPU > 70%
- 5-minute cooldown before scaling down
- `autoscaling/v2` API

### Cluster Autoscaler
- Watches for Pending pods (nodes at capacity)
- Calls AWS ASG `SetDesiredCapacity` API → new node joins in ~2 min
- Auto-discovery via ASG tags: `k8s.io/cluster-autoscaler/enabled=true`, `k8s.io/cluster-autoscaler/<cluster-name>=owned`
- Scales down after 10 min of node underutilization

**Proven end-to-end**: load test → HPA 2→3 pods → 3rd pod Pending (nodes full) → Cluster Autoscaler → 3rd node added → pod scheduled.

---

## Monitoring (kube-prometheus-stack)

Single Helm chart installs: Prometheus + Grafana + node-exporter + kube-state-metrics.

```bash
# Grafana password (auto-generated by Terraform)
terraform -chdir=terraform output -raw grafana_admin_password

# Port-forward
kubectl port-forward svc/prometheus-grafana -n monitoring 3001:80
```

Alertmanager disabled to reduce memory pressure on t3.small nodes.

---

## CI/CD Pipeline

```
apps/** push
    │
    ▼
ci-build-push.yml
  → build frontend + api in parallel
  → Trivy vulnerability scan
  → push to ECR (tagged with short git SHA)
    │ on success (workflow_run trigger)
    ▼
deploy.yml
  → helm upgrade frontend (new image tag)
  → helm upgrade api (new image tag)
  → kubectl rollout status ← fails workflow if pods don't come up

terraform/** PR
    │
    ▼
terraform-plan.yml
  → gitleaks (secrets scan)
  → tflint + tfsec (lint + misconfiguration scan)
  → infracost (cost delta vs main)
  → terraform plan → posts result as PR comment

terraform/** push to main
    │
    ▼
terraform-apply.yml
  → terraform apply -auto-approve
```

### OIDC Authentication
No static AWS credentials in GitHub. On each run:
1. GitHub Actions requests a short-lived OIDC token from GitHub
2. AWS validates it against the `github-actions-terraform` role trust policy (scoped to exact repo + branch)
3. GHA assumes the role and gets temporary credentials (valid 1 hr max)

### Image Tagging
Short 7-char git SHA only (e.g. `9b04499`). No `latest` tag — every deployment is pinned to an exact commit for traceability and easy rollback.

---

## IAM Roles

| Role | Assumed by | Purpose |
|---|---|---|
| `github-actions-terraform` | GitHub Actions (OIDC) | Run terraform plan/apply, helm deploy |
| `demo-dev-eks-role` | EKS control plane (`eks.amazonaws.com`) | Manage EKS cluster |
| `demo-dev-eks-node-role` | EC2 worker nodes (`ec2.amazonaws.com`) | Join cluster, pull ECR images |
| `demo-dev-eks-ebs-csi-role` | `kube-system:ebs-csi-controller-sa` (IRSA) | Provision EBS volumes |
| `demo-dev-eks-cluster-autoscaler-role` | `kube-system:cluster-autoscaler` (IRSA) | Scale ASG nodes |

`terraform-learner` is an **IAM user** — used for local AWS CLI and kubectl. Explicitly granted EKS cluster-admin via `aws_eks_access_entry` + `aws_eks_access_policy_association`.

---

## EKS Auth Design

```
EKS cluster created by GHA role
    │
    ├── access_config: API_AND_CONFIG_MAP  ← set at creation (immutable)
    │
    ├── aws_eks_access_entry (terraform-learner IAM user)
    ├── aws_eks_access_policy_association → AmazonEKSClusterAdminPolicy
    ├── aws_eks_access_entry (github-actions-terraform role)
    └── aws_eks_access_policy_association → AmazonEKSClusterAdminPolicy
```

> `access_config` **must be set at cluster creation time** — changing it on an existing cluster forces destroy + recreate.

---

## Remote State

| Resource | Details |
|---|---|
| S3 bucket | `karan-tf-state-259851212818` (versioning enabled) |
| State key | `aws-microservices-demo/dev/terraform.tfstate` |
| Lock mechanism | DynamoDB table `terraform-state-lock` |
| Bootstrap state | `bootstrap/terraform.tfstate` — OIDC provider + GHA IAM role, never destroyed |

---

## Issues Encountered and Fixed

| Issue | Root Cause | Fix Applied |
|---|---|---|
| Secrets Manager blocked on re-apply | 30-day recovery window prevents immediate re-creation | `recovery_window_in_days = 0` |
| State lock migration failure | Switching `dynamodb_table` → `use_lockfile` mid-session caused checksum mismatch | Reverted to `dynamodb_table` |
| EKS t3.medium blocked | New AWS account vCPU quota | Changed to `t3.small` |
| kubectl access denied after apply | EKS cluster created by GHA role; local user had no access | `access_config + aws_eks_access_entry` baked in from start |
| OIDC provider destroyed with full destroy | OIDC + IAM role were in the same state as infra | Moved to `bootstrap/` state — separate, never destroyed |
| CD workflow skipped on `workflow_dispatch` | `if` condition excluded `workflow_dispatch` event | Deploy manually via `helm upgrade` or add `workflow_dispatch` to trigger |
| ErrImagePull after cluster recreate | ECR repos recreated by Terraform — old image SHA no longer exists | Trigger CI build to push fresh images with new SHA |
| Cluster Autoscaler CrashLoopBackOff | IRSA trust policy expected SA `cluster-autoscaler` but Helm chart default is `cluster-autoscaler-aws-cluster-autoscaler` | Set `rbac.serviceAccount.name = "cluster-autoscaler"` in helm_release |
| Load generator pod Pending | t3.small nodes full (~11 pod limit), monitoring stack consumed all slots | Ran load test from inside existing pod via `kubectl exec` |
| kubectl hitting AKS instead of EKS | Running EKS and AKS simultaneously — kubeconfig context switches | Always use `--context arn:aws:eks:us-east-1:259851212818:cluster/demo-dev-eks` |

---

## Cost Notes

- NAT Gateway + RDS + EKS = ~$3–4/day when running
- OIDC provider + IAM roles = free (permanent, always live in bootstrap state)
- Cluster destroyed after each session to avoid idle costs
- Infracost PR check shows cost delta on every terraform PR
- Potential saving: switch `t3.small` → `t4g.small` (ARM Graviton, ~20% cheaper)
