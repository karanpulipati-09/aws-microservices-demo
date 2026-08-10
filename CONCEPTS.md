# AWS + Terraform Concepts Reference

Quick reference for concepts learned while building this project.

---

## VPC (Virtual Private Cloud)

Your own isolated private network inside AWS.

```
AWS = massive shared data center
VPC = your private walled-off section
```

- CIDR 10.0.0.0/16 = 65,536 IP addresses
- Nothing outside can reach resources inside by default
- One VPC per project/environment (dev, prod)

---

## Subnets

Smaller slices carved out of the VPC CIDR.

| Tier | CIDR | Lives here | Internet IN | Internet OUT |
|---|---|---|---|---|
| Public | 10.0.1-2.0/24 | ALB | YES | YES |
| Private | 10.0.10-11.0/24 | EC2 | NO | YES (via NAT) |
| DB | 10.0.20-21.0/24 | RDS | NO | NO |

**Why 3 tiers?** Each tier has different threat exposure. DB should never be reachable from internet. EC2 should not be directly reachable either — only ALB can talk to it.

**Why 2 AZs?** High availability. If one data center goes down, traffic shifts to the other automatically. ALB requires minimum 2 AZs.

---

## Internet Gateway (IGW)

Connects the VPC to the internet.

- Attached to the VPC (one per VPC)
- Public subnets route traffic through IGW
- Without IGW, nothing in the VPC can reach internet

---

## NAT Gateway

One-way door for private subnet resources to reach internet outbound.

```
EC2 → NAT Gateway (public subnet) → IGW → Internet   ✅ outbound works
Internet → NAT Gateway → EC2                          ❌ inbound blocked
```

- Lives in the **public subnet** (needs IGW to reach internet)
- Has a fixed **Elastic IP** (public IP)
- From internet's view, all private subnet traffic comes from NAT's IP
- EC2 stays hidden — internet never knows EC2's private IP
- Cost: ~$0.045/hr — always destroy after learning sessions

---

## Route Tables

GPS rules per subnet — tells traffic where to go.

| Route Table | Rule | Attached to |
|---|---|---|
| Public | 0.0.0.0/0 → IGW | Public subnets |
| Private | 0.0.0.0/0 → NAT Gateway | Private subnets |
| DB | no internet route | DB subnets |

**`aws_route_table_association`** — connects a subnet to a route table. Without it, subnet uses default VPC route table.

```
Route table alone = just rules sitting there
Route table + Association = subnet follows those rules
```

---

## Security Groups

Firewall around each AWS resource. Controls who can talk to whom.

**Ingress** = traffic coming IN to the resource
**Egress** = traffic going OUT from the resource

### Our Security Groups

| SG | Direction | Port | From/To |
|---|---|---|---|
| ALB SG | Ingress | 80 | 0.0.0.0/0 (internet) |
| ALB SG | Egress | 80 | EC2 SG only |
| EC2 SG | Ingress | 80 | ALB SG only |
| EC2 SG | Egress | all | 0.0.0.0/0 (via NAT) |

**Why `source_security_group_id` instead of `cidr_blocks`?**
ALB's IP address changes — but its SG ID never changes. Reference the SG ID for cross-resource rules.

**Circular dependency fix:**
ALB SG needs EC2 SG ID. EC2 SG needs ALB SG ID. Solution — create both SGs empty first, then add rules separately using `aws_security_group_rule`.

---

## ALB (Application Load Balancer)

Distributes incoming HTTP traffic across EC2 instances.

```
Internet → ALB (public subnet) → Target Group → EC2
```

**Components:**

| Resource | Purpose |
|---|---|
| `aws_lb` | The load balancer itself — internet-facing, in public subnets |
| `aws_lb_target_group` | Pool of EC2s to send traffic to |
| `aws_lb_target_group_attachment` | Registers a specific EC2 into the target group |
| `aws_lb_listener` | Rule — port 80 incoming → forward to target group |

**Health check** — ALB pings EC2 every 30 seconds on `/`. If EC2 fails 2 checks, ALB stops sending traffic to it.

**Why ALB in public subnet?** ALB needs to receive traffic from internet. Public subnet has route to IGW. EC2 stays safe in private subnet — only reachable from ALB.

---

## EC2 (Elastic Compute Cloud)

Virtual machine running your application.

- Lives in **private subnet** — no direct internet access
- Reached only through ALB
- Outbound internet via NAT Gateway (for package installs)
- `user_data` — bash script that runs once on first boot

```bash
# Our user_data installs nginx on boot
dnf install -y nginx
systemctl start nginx
```

**AMI (Amazon Machine Image)** — the OS image for EC2. Use `data "aws_ami"` block to auto-detect latest Amazon Linux 2023 instead of hardcoding an ID.

---

## EBS (Elastic Block Store)

Hard drive attached to EC2. Created automatically when EC2 is launched.

- Default: 8 GB gp3 SSD
- Deleted when EC2 is destroyed (unless configured otherwise)
- Customize with `root_block_device` block in `aws_instance`

---

## Terraform Concepts

### `data` block
Read-only. Fetches existing information from AWS without creating anything.
```hcl
data "aws_ami" "amazon_linux" { ... }  # asks AWS: what's the latest AMI?
```

### `count` pattern
One resource block → multiple resources.
```hcl
resource "aws_subnet" "public" {
  count      = length(var.public_subnet_cidrs)   # = 2
  cidr_block = var.public_subnet_cidrs[count.index]
}
# count.index = 0 → first subnet, count.index = 1 → second subnet
```

### Module outputs vs Root outputs
- **Module outputs** — share data between modules (inside Terraform)
- **Root outputs** — print to terminal after `terraform apply` (for you to see)

### When to run `terraform init`
- Adding a new module source (local or external) → **YES, run init**
- Adding a resource inside existing module → **NO**
- Changing variable values → **NO**

### `terraform init` is idempotent
Running it multiple times is safe — already installed modules just show blank under "Initializing modules".

---

## Traffic Flow — Full Picture

```
Browser
  ↓ HTTP port 80
Internet Gateway
  ↓
ALB (public subnet — us-east-1a + us-east-1b)
  ↓ picks healthy EC2, port 80
EC2 (private subnet — us-east-1a)
  ↓ nginx serves HTML page
response back to browser

EC2 outbound (package installs):
EC2 → NAT Gateway → IGW → Internet → response back to EC2
```

---

## Default AWS Resources (always exist, ignore them)

| Resource | Why it exists |
|---|---|
| Default VPC | AWS creates one per region automatically |
| Default Security Group | Every VPC gets one automatically |

These are harmless — nothing uses them in our setup.
