# aws-microservices-demo — Architecture

## Overview

A 3-tier AWS architecture (ALB → EC2 → RDS) with EKS, provisioned via Terraform modules and deployed through a GitHub Actions CI/CD pipeline using OIDC authentication.

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
[Secrets Manager] ← stores DB password (random_password)
    │
[EKS Cluster] ← private subnets, 2x t3.micro worker nodes
    │
[kubectl / k8s manifests] ← nginx Deployment + LoadBalancer Service
```

---

## VPC Layout (Multi-AZ)

| Subnet Type | AZ-a (us-east-1a) | AZ-b (us-east-1b) | Purpose |
|---|---|---|---|
| Public | 10.0.1.0/24 | 10.0.2.0/24 | ALB |
| Private | 10.0.10.0/24 | 10.0.11.0/24 | EC2 + EKS nodes |
| DB | 10.0.20.0/24 | 10.0.21.0/24 | RDS only |

- **NAT Gateway** in public subnet → private subnet EC2/EKS nodes can reach internet (outbound only)
- **Internet Gateway (IGW)** → public subnets have full internet access (inbound + outbound)

---

## Terraform Modules

| Module | Resources | Key Concept |
|---|---|---|
| `vpc` | VPC, subnets, IGW, NAT Gateway, route tables | Multi-AZ, NAT Gateway pattern |
| `ec2` | EC2 instance, AMI data source | Private subnet + user_data (nginx) |
| `alb` | ALB, target group, listener | Internet-facing, health checks |
| `rds` | RDS MySQL 8.0, subnet group | db.t3.micro, skip_final_snapshot |
| `eks` | EKS cluster, node group, IAM roles | API_AND_CONFIG_MAP auth mode |

> **Note**: Security groups are defined at root level (not inside modules) because ALB SG and EC2 SG reference each other — a circular dependency Terraform can only resolve when both are in the same scope.

---

## Kubernetes (EKS)

Manifests in `k8s/`:

| File | Resource | Details |
|---|---|---|
| `deployment.yaml` | Deployment | 2 replicas, nginx:latest, port 80 |
| `service.yaml` | Service (LoadBalancer) | Provisions an AWS ELB, exposes port 80 |

Deploy flow:
```
terraform apply → EKS cluster + nodes ready
    │
    ▼
aws eks update-kubeconfig --region us-east-1 --name demo-dev-eks
    │
    ▼
kubectl apply -f k8s/
    │
    ▼
kubectl get service nginx → ELB DNS name → open in browser
```

---

## CI/CD Pipeline (GitHub Actions + OIDC)

```
PR opened
    │
    ▼
terraform-plan.yml
  → terraform init (provider cache restored if available)
  → terraform plan
  → posts plan output as PR comment
    │
    ▼ (merge to main)
terraform-apply.yml
  → terraform init
  → terraform apply -auto-approve
```

### OIDC Authentication
No static AWS credentials stored in GitHub. On each run:
1. GitHub Actions requests a short-lived OIDC token
2. AWS validates it against the `github-actions-terraform` IAM role trust policy
3. GHA assumes the role and gets temporary credentials (valid 15 min – 1 hr)

### Provider Caching
`terraform/.terraform` directory is cached via `actions/cache@v4`, keyed by `.terraform.lock.hcl` hash. Skips provider download on repeat runs.

---

## IAM Roles

| Role | Assumed by | Purpose |
|---|---|---|
| `github-actions-terraform` | GitHub Actions (OIDC) | Run terraform plan/apply |
| `demo-dev-eks-role` | EKS control plane (`eks.amazonaws.com`) | Manage EKS cluster |
| `demo-dev-eks-node-role` | EC2 worker nodes (`ec2.amazonaws.com`) | Join cluster, pull ECR images |

`terraform-learner` is an **IAM user** (not a role) — used for local AWS CLI and kubectl access. Explicitly granted EKS cluster-admin via `aws_eks_access_entry` + `aws_eks_access_policy_association`.

---

## EKS Auth Design

```
EKS cluster created by GHA role
    │
    ├── access_config: API_AND_CONFIG_MAP  ← set at creation (immutable)
    │
    ├── aws_eks_access_entry (terraform-learner)
    └── aws_eks_access_policy_association → AmazonEKSClusterAdminPolicy
```

> `access_config` **must be set at cluster creation time** — changing it on an existing cluster forces a destroy + recreate.

---

## Remote State

| Resource | Details |
|---|---|
| S3 bucket | `karan-tf-state-259851212818` (versioning enabled) |
| State key | `aws-microservices-demo/dev/terraform.tfstate` |
| Lock mechanism | DynamoDB table `terraform-state-lock` |

---

## Route53 — Custom Domain (Concept)

Not implemented (cost ~$12/year for domain), but the pattern for production:

```
User → demo.yourdomain.com
    │
    ▼
Route53 Hosted Zone
  ALIAS record → ELB DNS name
    │
    ▼
EKS LoadBalancer
```

Key points:
- Use **ALIAS** record (not CNAME) — ELBs have DNS names, not fixed IPs
- ALIAS is AWS-native, free, and works on apex domains (CNAME doesn't)
- Terraform resource: `aws_route53_record` with `alias {}` block pointing to the ELB hostname

---

## Issues Encountered and Fixed

| Issue | Root Cause | Fix Applied |
|---|---|---|
| Secrets Manager blocked on re-apply | 30-day recovery window prevents immediate re-creation | Set `recovery_window_in_days = 0` in main.tf |
| State lock migration failure | Switching `dynamodb_table` → `use_lockfile` mid-session caused DynamoDB checksum mismatch | Reverted to `dynamodb_table`; backend config changes need a maintenance window |
| EKS t3.medium blocked | New AWS account Free Tier restriction | Changed node group to `t3.micro` |
| kubectl access denied after apply | EKS cluster created by GHA role; local IAM user had no access | Full destroy + clean apply with `access_config` + `aws_eks_access_entry` baked in from the start |
| OIDC provider destroyed with full destroy | OIDC + IAM role were in the same Terraform state — `terraform destroy` wiped them | Recreate manually via AWS CLI → `terraform import` to bring back into state |
| `terraform import` failing with count error | State was empty; VPC module `count = length(aws_subnet.public)` can't evaluate with no state | Temporarily comment out all modules in main.tf + outputs.tf → run imports → restore |

---

## Cost Notes

- NAT Gateway + RDS = ~$2/day when running
- OIDC provider + IAM roles = free (permanent, always live)
- Everything else is destroyed after each session
- AWS budget: ~$133 remaining (as of 2026-07-21)
