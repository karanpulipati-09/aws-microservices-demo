## aws-microservices-demo

Multi-tier AWS infrastructure built with Terraform. Demonstrates production-grade networking, compute, load balancing, database, EKS, and CI/CD patterns.

## Architecture

```
Internet
    ↓ HTTP port 80
ALB  (public subnets — us-east-1a, us-east-1b)
    ↓ HTTP port 80 (ALB SG → EC2 SG only)
EC2  (private subnet)  ← nginx
    ↓ MySQL port 3306 (EC2 SG → RDS SG only)
RDS  (DB subnet)  ← MySQL 8.0

EKS Cluster (private subnets — 2x t3.micro nodes)
    └── nginx Deployment (2 replicas) + LoadBalancer Service

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
| EKS Cluster | Kubernetes cluster in private subnets (v1.30) |
| EKS Node Group | 2x t3.micro worker nodes with Auto Scaling (min 1, max 3) |
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

## Modules

| Module | What it creates |
|---|---|
| `modules/vpc` | VPC, subnets, IGW, NAT gateway, route tables |
| `modules/ec2` | EC2 instance with nginx, AMI auto-detected |
| `modules/alb` | ALB, target group, listener, target group attachment |
| `modules/rds` | RDS MySQL, DB subnet group, RDS security group |
| `modules/eks` | EKS cluster, node group, IAM roles for control plane + nodes |

## Kubernetes

Manifests in `k8s/`:

| File | Resource | Details |
|---|---|---|
| `deployment.yaml` | Deployment | 2 replicas, nginx:latest, port 80 |
| `service.yaml` | Service (LoadBalancer) | Provisions an AWS ELB, exposes port 80 |

After EKS apply:
```bash
aws eks update-kubeconfig --region us-east-1 --name demo-dev-eks
kubectl apply -f k8s/
kubectl get service nginx  # get LoadBalancer URL
```

> **Note**: Delete kubernetes Services before destroying infra — `kubectl delete -f k8s/` — otherwise the ELB created by the Service will block VPC subnet deletion.

## CI/CD

All infrastructure changes go through GitHub Actions — no manual terraform commands.

| Workflow | Trigger | What it does |
|---|---|---|
| `terraform-plan.yml` | Pull Request to `main` | Runs terraform plan, posts result as PR comment |
| `terraform-apply.yml` | Merge to `main` | Runs terraform apply automatically |
| `terraform-destroy.yml` | Manual (workflow_dispatch) | Destroys all resources via GitHub UI button |

**Authentication**: OIDC — no AWS access keys stored in GitHub. GitHub proves its identity to AWS and assumes an IAM role with temporary credentials (valid 15 min–1 hr).

**Provider caching**: `.terraform` directory cached via `actions/cache@v4` keyed on `.terraform.lock.hcl` — skips provider download on subsequent runs.

**Terraform version**: 1.15.x

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
| OIDC provider + GHA IAM role + policy | 3 |
| **Total** | **49** |

**Always destroy after use — NAT Gateway + RDS cost ~$2/day.**
