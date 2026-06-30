# aws-microservices-demo

Multi-tier AWS infrastructure built with Terraform. Demonstrates production-grade networking, compute, load balancing, and CI/CD patterns.

## Architecture

```
Internet
    ↓ HTTP port 80
ALB  (public subnets — us-east-1a, us-east-1b)
    ↓ HTTP port 80 (ALB SG → EC2 SG only)
EC2  (private subnet — us-east-1a)  ← nginx
    ↓ SQL port 3306 (coming soon)
RDS  (DB subnet — coming soon)

EC2 outbound:
EC2 → NAT Gateway → Internet (package installs)
```

## Infrastructure

| Resource | Purpose |
|---|---|
| VPC | Isolated private network — 3 subnet tiers across 2 AZs |
| Internet Gateway | Public internet access for ALB |
| NAT Gateway | Outbound-only internet for private EC2 |
| Security Groups | ALB SG (port 80 from internet) + EC2 SG (port 80 from ALB only) |
| ALB | Internet-facing load balancer in public subnets |
| EC2 | App server running nginx in private subnet |
| RDS MySQL | Database in isolated DB subnet (coming soon) |
| Secrets Manager | DB credentials — never hardcoded (coming soon) |
| S3 + DynamoDB | Terraform remote state + state locking |

## Security

- EC2 is in a **private subnet** — not directly reachable from internet
- EC2 security group allows port 80 **only from ALB security group**
- ALB security group allows port 80 from internet, egress to EC2 only
- No SSH keys — EC2 access via AWS Systems Manager (SSM) if needed

## Modules

| Module | What it creates |
|---|---|
| `modules/vpc` | VPC, subnets, IGW, NAT gateway, route tables |
| `modules/ec2` | EC2 instance with nginx, AMI auto-detected |
| `modules/alb` | ALB, target group, listener, target group attachment |
| `modules/rds` | RDS MySQL (coming soon) |

## Usage

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

After apply, the terminal prints:

```
alb_dns_name = "demo-dev-alb-XXXX.us-east-1.elb.amazonaws.com"
```

Open that URL in your browser to see the nginx page.

## CI/CD (coming soon)

| Workflow | Trigger | What it does |
|---|---|---|
| `terraform-plan.yml` | Pull Request | Runs plan, posts result as PR comment |
| `terraform-apply.yml` | Merge to main | Applies the saved plan |

Both will use **OIDC authentication** — no AWS access keys stored in GitHub.

## Resources created

| Resource | Count |
|---|---|
| VPC | 1 |
| Internet Gateway | 1 |
| Elastic IP | 1 |
| NAT Gateway | 1 |
| Subnets (public + private + DB) | 6 |
| Route tables + associations | 9 |
| Security groups | 2 |
| Security group rules | 4 |
| EC2 instance | 1 |
| ALB + target group + listener + attachment | 4 |
| **Total** | **30** |
