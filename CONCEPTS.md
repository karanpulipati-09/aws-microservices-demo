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

---

## EKS (Elastic Kubernetes Service)

AWS-managed Kubernetes control plane. You pay for worker nodes — the master is free.

```
EKS Control Plane (AWS-managed)
    ├── API server   ← kubectl talks here
    ├── etcd         ← stores cluster state
    └── scheduler    ← decides which node gets a pod

EKS Node Group (your EC2s)
    ├── node-1 (t3.small)
    └── node-2 (t3.small)
```

- **Node Group** = Auto Scaling Group of EC2s — Terraform manages desired/min/max
- **Authentication modes**: `API_AND_CONFIG_MAP` — supports both aws-auth ConfigMap and newer access entries API. Set at cluster creation — **immutable**, changing it forces destroy + recreate.
- **Access entries** (`aws_eks_access_entry` + `aws_eks_access_policy_association`) — the modern way to grant IAM users/roles kubectl access without editing ConfigMap manually.

---

## IRSA (IAM Roles for Service Accounts)

Lets a Kubernetes pod assume an AWS IAM role — no credentials stored in the cluster.

```
Pod SA annotated with role ARN
    │
    ▼
EKS OIDC Provider issues a projected token for the SA
    │
    ▼
AWS STS validates token → AssumeRoleWithWebIdentity
    │
    ▼
Pod gets temporary IAM credentials (auto-rotated)
```

**Three parts you need:**
1. **OIDC provider** — bridges EKS and AWS IAM trust (`aws_iam_openid_connect_provider`)
2. **IAM role trust policy** — `StringEquals` condition scoped to exact `namespace:service-account`
3. **SA annotation** — `eks.amazonaws.com/role-arn: <arn>` on the Kubernetes SA

**Common gotcha**: trust policy SA name must exactly match what the pod actually uses. Helm charts often create SAs with different default names (e.g. `cluster-autoscaler-aws-cluster-autoscaler` vs `cluster-autoscaler`).

---

## EBS CSI Driver

Allows EKS pods to use EBS volumes as PersistentVolumes.

- Installed as an EKS **addon** (`aws_eks_addon`)
- Needs IRSA — the controller pod calls EBS APIs to create/attach/detach volumes
- **gp3** StorageClass — faster baseline throughput + IOPS than gp2, and cheaper
- `WaitForFirstConsumer` binding mode — EBS volume created in the same AZ as the pod (EBS is AZ-scoped)

```
PVC created → StorageClass (gp3) → EBS CSI Driver → AWS creates EBS volume → attaches to node → mounted in pod
```

---

## Helm

Package manager for Kubernetes. A **chart** is a template for Kubernetes manifests.

```
helm install <release-name> <chart> -n <namespace> -f values.yaml
helm upgrade <release-name> <chart> -n <namespace> --set image.tag=abc1234
helm uninstall <release-name> -n <namespace>
```

- **Release** = a deployed instance of a chart (can install same chart multiple times with different names)
- **Values** = inputs that parameterize the templates (`values.yaml` or `--set key=value`)
- **`helm upgrade --install`** = idempotent — installs if not present, upgrades if already running

**Templates** use Go templating:
```yaml
replicas: {{ .Values.replicaCount }}
image: {{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- if .Values.hpa.enabled }}   # conditional block
```

---

## HPA (Horizontal Pod Autoscaler)

Automatically scales pod replicas based on CPU or memory.

```
metrics-server → reads CPU/memory from pods every 15s
    │
HPA controller polls metrics-server
    │
if avg CPU > target → scale up replicas
if avg CPU < target for 5 min → scale down replicas
```

**Key design decision**: omit `replicas` from Deployment when HPA is enabled. If `replicas: 2` is in the Deployment, `helm upgrade` resets replica count to 2 on every deploy — fighting the HPA. With `replicas` omitted, HPA is the sole owner.

```yaml
# values.yaml
hpa:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70

# deployment.yaml
spec:
  {{- if not .Values.hpa.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
```

- API version: `autoscaling/v2` (supports multiple metrics)
- Scale-up: immediate when threshold crossed
- Scale-down: 5-minute cooldown (prevents flapping)

---

## Cluster Autoscaler

Scales EC2 **nodes** (not pods). Works at the AWS ASG level.

```
Pod scheduled → no node has capacity → pod stays Pending
    │
Cluster Autoscaler sees Pending pod
    │
Calls AWS ASG SetDesiredCapacity +1
    │
New EC2 node boots, joins cluster (~2 min)
    │
Pending pod gets scheduled on new node
```

**Scale-down**: node underutilized for 10 min → drains pods → terminates EC2.

**Setup requirements:**
1. ASG auto-discovery tags on node group:
   - `k8s.io/cluster-autoscaler/enabled=true`
   - `k8s.io/cluster-autoscaler/<cluster-name>=owned`
2. IRSA role with ASG permissions (`SetDesiredCapacity`, `TerminateInstanceInAutoScalingGroup`)
3. Helm chart with `rbac.serviceAccount.name` matching the IRSA trust policy SA name

---

## RBAC (Role-Based Access Control)

Controls what Kubernetes identities (users, SAs) can do inside the cluster.

```
Role          = what actions are allowed (in a namespace)
ClusterRole   = same but cluster-wide
RoleBinding   = binds a Role to a user/SA (in a namespace)
ClusterRoleBinding = binds a ClusterRole cluster-wide
```

**Our setup** (in `dev` namespace):

| Resource | Verbs | Who |
|---|---|---|
| `dev-readonly` Role | get, list, watch | `dev-readonly` SA |
| `dev-admin` Role | `*` (everything) | `dev-admin` SA |

**Principle of least privilege**: readonly SA can't create or delete anything. Admin SA is scoped to `dev` namespace only — can't touch `kube-system`.

---

## Prometheus + Grafana (kube-prometheus-stack)

Single Helm chart installs the full monitoring stack:

| Component | Purpose |
|---|---|
| Prometheus | Scrapes metrics from pods every 15s, stores time-series |
| Grafana | Dashboards on top of Prometheus |
| node-exporter | Per-node metrics (CPU, memory, disk) |
| kube-state-metrics | Kubernetes object metrics (pod status, deployment replicas) |
| Alertmanager | Routes alerts to Slack/PagerDuty (disabled in our setup to save memory) |

**How Prometheus discovers targets**: `ServiceMonitor` CRDs — label-selects Services to scrape. Setting `serviceMonitorSelectorNilUsesHelmValues: false` lets it scrape all namespaces, not just ones with Helm labels.

**Grafana access:**
```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3001:80
# Login: admin / $(terraform output -raw grafana_admin_password)
```

---

## Terraform — Advanced Concepts

### `depends_on`
Explicit dependency for relationships Terraform can't detect via variable references.
```hcl
resource "helm_release" "metrics_server" {
  depends_on = [module.eks]  # EKS must be fully ready before Helm can talk to it
}
```
Use when: provider connection depends on a resource being ready (EKS cluster, VPC endpoint).

### `count` vs `for_each`

| | `count` | `for_each` |
|---|---|---|
| Index | Number (`count.index`) | String key (map/set) |
| Reference | `aws_subnet.public[0]` | `aws_subnet.public["us-east-1a"]` |
| Risk | Remove middle item → all after it recreate | Remove any item → only that item destroyed |
| Use when | Identical resources | Named/distinct resources |

### `terraform workspace`
Separate state files within one backend. Weak isolation — all workspaces share the same Terraform code.
```bash
terraform workspace new staging
terraform workspace select prod
```
**Preferred in production**: separate state files per environment (separate S3 keys + separate backend configs). Workspaces share variables and code, making cross-environment drift hard to catch.

### State file corruption
- **Prevention**: S3 versioning + DynamoDB locking — only one person applies at a time
- **Recovery**: `aws s3 cp s3://bucket/key.tfstate.backup terraform.tfstate` → `terraform state push`
- **Never** edit state manually — use `terraform state mv`, `terraform state rm`, `terraform import`

### `terraform taint` (deprecated)
Replaced by `terraform apply -replace=<resource>`:
```bash
terraform apply -replace="aws_instance.web"
```
Forces destroy + recreate of a specific resource on next apply, without changing config.

### Provider vs Provisioner

| | Provider | Provisioner |
|---|---|---|
| What | Plugin connecting Terraform to a platform (AWS, k8s, Helm) | Script runner inside a resource (remote-exec, local-exec) |
| When | Always — defines resource types | After resource creation — run commands on it |
| Avoid? | No — essential | Yes — use `user_data` instead; provisioners break idempotency |
