# Day 7 — Multi-AZ VPC (aws-microservices-demo)

## What we built

Production-grade VPC with 3 subnet tiers across 2 Availability Zones.

```
VPC (10.0.0.0/16)
├── Public Subnets  (10.0.1.0/24, 10.0.2.0/24)   us-east-1a + us-east-1b  → ALB
├── Private Subnets (10.0.10.0/24, 10.0.11.0/24)  us-east-1a + us-east-1b  → EC2
└── DB Subnets      (10.0.20.0/24, 10.0.21.0/24)  us-east-1a + us-east-1b  → RDS
```

19 resources created. Pushed to GitHub: karanpulipati-09/aws-microservices-demo

---

## 1. VPC

Your own isolated private network inside AWS.

```
AWS = massive shared data center
VPC = your private walled-off section
```

- CIDR 10.0.0.0/16 = 65,536 IP addresses (10.0.0.0 → 10.0.255.255)
- Subnets carve smaller slices out of this range
- By default nothing outside can reach resources inside

---

## 2. 3 Subnet Tiers

| Tier | CIDR | Lives here | Internet IN | Internet OUT | Route |
|---|---|---|---|---|---|
| Public | 10.0.1-2.0/24 | ALB | YES | YES | → IGW |
| Private | 10.0.10-11.0/24 | EC2 | NO | YES (via NAT) | → NAT GW |
| DB | 10.0.20-21.0/24 | RDS | NO | NO | nothing |

**Why isolate?** Each tier has a different threat exposure. DB should never be reachable from internet. EC2 should not be directly reachable either — only ALB can talk to it.

---

## 3. NAT Gateway — One-Way Door

EC2 is in private subnet but still needs outbound internet (package installs, Docker pulls).

```
EC2 → NAT Gateway (public subnet) → IGW → Internet   ✅ outbound works
Internet → NAT Gateway → BLOCKED                      ❌ inbound blocked
```

- NAT Gateway has a fixed Elastic IP
- From internet's view, all private subnet traffic comes from that one IP
- Cost: ~$32/month — always destroy after learning sessions

---

## 4. Route Tables

Traffic rules per subnet tier:

**Public:**
```
10.0.0.0/16 → local
0.0.0.0/0   → Internet Gateway
```

**Private:**
```
10.0.0.0/16 → local
0.0.0.0/0   → NAT Gateway
```

**DB:**
```
10.0.0.0/16 → local
(no internet route)
```

`aws_route_table_association` connects each subnet to its route table.

---

## 5. Availability Zones — Why 2?

AZ = physically separate data center within a region.

```
us-east-1
├── us-east-1a  → building A (own power, cooling, networking)
└── us-east-1b  → building B
```

If us-east-1a goes down → traffic shifts to us-east-1b automatically.
ALB requires minimum 2 AZs to function.

---

## 6. count Pattern

One resource block → multiple resources:

```hcl
resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)    # = 2
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
}
```

- count.index = 0 → 10.0.1.0/24, us-east-1a
- count.index = 1 → 10.0.2.0/24, us-east-1b
- Reference all: `aws_subnet.public[*].id` → list of both IDs

---

## 7. Full Traffic Flow

```
Browser
  ↓ HTTPS
Internet Gateway
  ↓
ALB (public subnet)
  ↓ picks healthy EC2
EC2 (private subnet)
  ↓ SQL on port 3306
RDS (DB subnet)
  ↓ result
EC2 → ALB → Browser
```

EC2 outbound (package install):
```
EC2 → NAT Gateway → IGW → Internet → response back
```

---

## Resources created

| Resource | Count | Name pattern |
|---|---|---|
| VPC | 1 | demo-dev-vpc |
| Internet Gateway | 1 | demo-dev-igw |
| Elastic IP | 1 | demo-dev-nat-eip |
| NAT Gateway | 1 | demo-dev-nat |
| Public subnets | 2 | demo-dev-public-subnet-1/2 |
| Private subnets | 2 | demo-dev-private-subnet-1/2 |
| DB subnets | 2 | demo-dev-db-subnet-1/2 |
| Route tables | 3 | demo-dev-public/private/db-rt |
| Route table associations | 6 | — |

---

## Current AWS state

- VPC + all subnets: RUNNING (costs minimal — VPC itself is free, NAT GW ~$0.045/hr)
- Remote state: karan-tf-state-259851212818/aws-microservices-demo/dev/terraform.tfstate

## Next session

- EC2 module — app server in private subnet, nginx
- Security groups — ALB SG + EC2 SG (only ALB can talk to EC2)
- ALB module — routes internet traffic to EC2
