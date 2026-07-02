# aws-microservices-demo

Multi-tier AWS infrastructure built with Terraform. Demonstrates production-grade networking, compute, load balancing, database, and CI/CD patterns.

## Architecture

```
Internet
    ↓ HTTP port 80
ALB  (public subnets — us-east-1a, us-east-1b)
    ↓ HTTP port 80 (ALB SG → EC2 SG only)
EC2  (private subnet — us-east-1a)  ← nginx
    ↓ MySQL port 3306 (EC2 SG → RDS SG only)
RDS  (DB subnet — us-east-1a)  ← MySQL 8.0

EC2 outbound:
EC2 → NAT Gateway → Internet (package installs)

Password flow:
random_password → Secrets Manager → RDS (never hardcoded)
```

## Infrastructure

| Resource | Purpose |
|---|---|
| VPC | Isolated private network — 3 subnet tiers across 2 AZs |
| Internet Gateway | Public internet access for ALB |
| NAT Gateway | Outbound-only internet for private EC2 |
| ALB SG | Port 80 from internet, egress to EC2 SG only |
| EC2 SG | Port 80 from ALB SG only, all outbound |
| RDS SG | Port 3306 from EC2 SG only |
| ALB | Internet-facing load balancer in public subnets |
| EC2 | App server running nginx in private subnet |
| RDS MySQL 8.0 | Database in isolated DB subnet, not publicly accessible |
| Secrets Manager | Auto-generated DB password stored securely |
| S3 + DynamoDB | Terraform remote state + state locking |

## Security

- EC2 is in a **private subnet** — not directly reachable from internet
- EC2 SG allows port 80 **only from ALB SG**
- RDS SG allows port 3306 **only from EC2 SG**
- DB subnet has **no internet route** — RDS completely isolated
- DB password **auto-generated** by Terraform, stored in Secrets Manager
- `publicly_accessible = false` on RDS — double protection
- No SSH keys — EC2 access via AWS Systems Manager (SSM) if needed

## Modules

| Module | What it creates |
|---|---|
| `modules/vpc` | VPC, subnets, IGW, NAT gateway, route tables |
| `modules/ec2` | EC2 instance with nginx, AMI auto-detected |
| `modules/alb` | ALB, target group, listener, target group attachment |
| `modules/rds` | RDS MySQL, DB subnet group, RDS security group |

## Usage

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

After apply, the terminal prints:

```
alb_dns_name   = "demo-dev-alb-XXXX.us-east-1.elb.amazonaws.com"
db_endpoint    = "demo-dev-mysql.XXXX.us-east-1.rds.amazonaws.com:3306"
db_secret_name = "demo-dev-db-password"
ec2_private_ip = "10.0.10.X"
```

Open `alb_dns_name` in your browser to see the nginx page.

**Always destroy after use — NAT Gateway + RDS cost ~$2/day.**

```bash
terraform destroy
```

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
| Security groups (ALB + EC2 + RDS) | 3 |
| Security group rules | 4 |
| EC2 instance | 1 |
| ALB + target group + listener + attachment | 4 |
| Random password + Secrets Manager | 3 |
| RDS DB subnet group + RDS instance | 2 |
| **Total** | **36** |
