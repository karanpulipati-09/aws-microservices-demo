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
`terraform/.terraform` directory is cached via `actions/cache@v4`, keyed by `.terraform.lock.hcl` hash. Skips provider download on repeat runs (~30s savings).

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

## Issues Encountered and Fixed

| Issue | Root Cause | Fix Applied |
|---|---|---|
| Secrets Manager blocked on re-apply | 30-day recovery window prevents immediate re-creation | Set `recovery_window_in_days = 0` in main.tf |
| State lock migration failure | Switching `dynamodb_table` → `use_lockfile` mid-session caused DynamoDB checksum mismatch | Reverted to `dynamodb_table`; backend config changes need a maintenance window |
| EKS t3.medium blocked | New AWS account Free Tier restriction | Changed node group to `t3.micro` |
| kubectl access denied after apply | EKS cluster created by GHA role; local IAM user had no access | Full destroy + clean apply with `access_config` + `aws_eks_access_entry` baked in from the start |

---

## Cost Notes

- NAT Gateway + RDS = ~$2/day when running
- OIDC provider + IAM roles = free (permanent, always live)
- Everything else is destroyed after each session
- AWS budget: ~$133 remaining (as of 2026-07-21)
