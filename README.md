# aws-microservices-demo

Multi-tier AWS infrastructure built with Terraform. Demonstrates production-grade networking, compute, database, and CI/CD patterns.

## Architecture

```
VPC (10.0.0.0/16)
├── Public Subnets  (us-east-1a, us-east-1b)  → ALB
├── Private Subnets (us-east-1a, us-east-1b)  → EC2 app servers
└── DB Subnets      (us-east-1a, us-east-1b)  → RDS MySQL

Internet → ALB → EC2 (private subnet) → RDS (DB subnet)
                  ↓
              NAT Gateway → internet (for package installs)
```

## Infrastructure

| Resource | Purpose |
|---|---|
| VPC | Isolated private network with 3 subnet tiers |
| Internet Gateway | Public internet access for ALB |
| NAT Gateway | Outbound-only internet for private subnet EC2 |
| ALB | Load balancer — routes HTTP traffic to EC2 |
| EC2 | App server running nginx (private subnet) |
| RDS MySQL | Database in isolated DB subnet |
| Secrets Manager | DB credentials — never hardcoded |
| S3 + DynamoDB | Terraform remote state + state locking |

## CI/CD

| Workflow | Trigger | What it does |
|---|---|---|
| `terraform-plan.yml` | Pull Request | Runs plan, posts result as PR comment |
| `terraform-apply.yml` | Merge to main | Applies the saved plan |

Both use **OIDC authentication** — no AWS access keys stored in GitHub.

## Usage

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

## Modules

- `modules/vpc` — VPC, subnets, IGW, NAT gateway, route tables
- `modules/ec2` — EC2 instance with security group (coming soon)
- `modules/rds` — RDS MySQL in private DB subnet (coming soon)
- `modules/alb` — Application Load Balancer (coming soon)
