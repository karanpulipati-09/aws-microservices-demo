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
[Secrets Manager] ← DB password + app credentials JSON (random_password, never hardcoded)

[EKS Cluster] ← private subnets, t3.small worker nodes (Cluster Autoscaler 1→5)
    ├── ingress-nginx     ← single ELB entry point, routes /api/* and /*
    ├── frontend          ← nginx (ECR), HPA: 2–5 replicas, CPU target 70%
    ├── api               ← Node.js tasks API (ECR), HPA: 2–5, talks to RDS MySQL
    ├── argocd            ← GitOps controller + api/frontend Applications (Terraform)
    ├── external-secrets  ← Secrets Manager → Kubernetes Secret (IRSA)
    ├── metrics-server    ← provides CPU/memory metrics for HPA
    ├── Prometheus        ← scrapes all workloads
    ├── Grafana           ← dashboards (kube-prometheus-stack)
    └── Cluster Autoscaler ← scales the node group (1→5) when pods are Pending

[ECR] ← frontend + api images (tagged by short git SHA, scan_on_push enabled)
[S3] ← Terraform remote state (native S3 locking, use_lockfile)

[Monitoring]
    ├── CloudWatch Alarms  → ALB 5xx errors, RDS replica lag
    ├── SNS Topic          → email subscription (optional)
    ├── EventBridge        → state bucket PutObject/DeleteObject events
    └── CloudTrail         → audit log of all S3 data events on state bucket
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
| `alb` | ALB, target group, HTTP listener, optional HTTPS listener | Internet-facing, health checks, TLS 1.2+ |
| `rds` | RDS MySQL 8.0, subnet group, encryption | db.t3.micro, skip_final_snapshot, 1-day backup (free tier) |
| `eks` | EKS cluster, node group, IAM roles, access entries, OIDC provider, EBS CSI IRSA + addon, Cluster Autoscaler IRSA | API_AND_CONFIG_MAP auth, IRSA pattern |
| `ecr` | ECR repos + lifecycle policy (keep last 5 images) | `scan_on_push = true` |
| `monitoring.tf` | CloudWatch alarms, SNS topic, CloudTrail, EventBridge | Observability + audit logging |

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
| `helm/api` (+ ExternalSecret, migration Job, ServiceMonitor, dashboard) | ClusterIP | 3000 | HPA: 2–5 (CPU 70%) | RollingUpdate maxSurge:1 maxUnavailable:1 |

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

GitOps: CI builds, CD records the new image tag in Git, ArgoCD pulls it into the cluster.

```
apps/** push
    │
    ▼
build-push.yml (CI)
  → build frontend + api in parallel
  → Trivy vulnerability scan
  → push to ECR (tagged with short git SHA)
    │ on success (workflow_run trigger)
    ▼
deploy.yml (CD)
  → update image tag in helm/*/values.yaml
  → commit to main ([skip ci])
    │
    ▼
ArgoCD detects the change and syncs the cluster
  → sync waves: SecretStore → ExternalSecret → migration Job → Deployment

terraform/** PR
    │
    ▼
terraform-plan.yml
  → gitleaks, tflint, tfsec, checkov, infracost
  → terraform plan → posted as a PR comment

terraform/** push to main
    │
    ▼
terraform-apply.yml → terraform apply -auto-approve
    │ on success (workflow_run trigger)
    ▼
build-push.yml (so ECR exists before the first image push) → deploy.yml → ArgoCD
```

### OIDC Authentication
No static AWS credentials in GitHub. On each run:
1. GitHub Actions requests a short-lived OIDC token from GitHub
2. AWS validates it against the `github-actions-terraform` role trust policy
3. GHA assumes the role and gets temporary credentials (valid 1 hr max)

### Image Tagging
Short 7-char git SHA only (e.g. `9b04499`). No `latest` tag — every deployment is pinned to an exact commit for traceability and easy rollback.

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
| Lock mechanism | DynamoDB table `terraform-state-lock` (or S3 native lockfile) |
| Bootstrap state | `bootstrap/terraform.tfstate` — OIDC provider + GHA IAM role, never destroyed |

**State lock recovery**: `terraform-apply.yml` includes an automatic `terraform force-unlock` step (timeout 60s) to clear stale locks from interrupted runs.

---

## Monitoring & Observability

### CloudWatch Alarms
- **ALB 5xx errors**: `HTTPCode_Target_5XX_Count > 5` in 5 min → SNS alert
- **RDS replica lag**: `ReplicaLag > 0.1s` sustained 5 min → SNS alert

### SNS Topic
- Optional email subscription via `alert_email` variable
- Receives alarm notifications and state bucket events

### CloudTrail
- Logs all S3 data events for the Terraform state bucket
- Stored in dedicated S3 bucket with proper CloudTrail service policy
- Captures `PutObject` and `DeleteObject` operations

### EventBridge Rule
- Pattern match: S3 events on `karan-tf-state-259851212818` bucket
- Target: SNS topic (alerts when state file is modified)

### Prometheus + Grafana (in-cluster)
- `kube-prometheus-stack` Helm chart
- Grafana password auto-generated by Terraform (`random_password`)
- Alertmanager disabled to reduce t3.small memory pressure

---

## Security Hardening (Recent Additions)

| Layer | Implementation |
|---|---|
| **RDS encryption** | `storage_encrypted = true` (AWS-managed KMS key, free tier) |
| **ALB HTTPS** | Optional HTTPS listener with `ELBSecurityPolicy-TLS-1-2-2017-01` |
| **Ingress headers** | HSTS (`max-age=63072000`) + CSP (`default-src 'self'`) |
| **Audit trail** | CloudTrail logging all state bucket access |
| **Alerting** | SNS topic with optional email subscription |
| **Pod Security** | `restricted` baseline + default-deny NetworkPolicy in `dev` |
| **CI linting** | tflint + tfsec + checkov fail PR on errors |

---

## Issues Encountered and Fixed

| Issue | Root Cause | Fix Applied |
|---|---|---|
| Secrets Manager blocked on re-apply | 30-day recovery window prevents immediate re-creation | `recovery_window_in_days = 0` |
| State lock migration failure | Switching `dynamodb_table` → `use_lockfile` mid-session caused checksum mismatch | Migrated cleanly later; the backend now uses native S3 locking (`use_lockfile = true`) |
| EKS t3.medium blocked | New AWS account vCPU quota | Changed to `t3.small` |
| kubectl access denied after apply | EKS cluster created by GHA role; local user had no access | `access_config + aws_eks_access_entry` baked in from start |
| OIDC provider destroyed with full destroy | OIDC + IAM role were in the same state as infra | Moved to `bootstrap/` state — separate, never destroyed |
| CD workflow skipped on `workflow_dispatch` | `if` condition excluded `workflow_dispatch` event | Added `workflow_dispatch` to the CD trigger and condition |
| ErrImagePull after cluster recreate | ECR repos recreated by Terraform — old image SHA no longer exists | Trigger CI build to push fresh images with new SHA |
| Cluster Autoscaler CrashLoopBackOff | IRSA trust policy expected SA `cluster-autoscaler` but Helm chart default is `cluster-autoscaler-aws-cluster-autoscaler` | Set `rbac.serviceAccount.name = "cluster-autoscaler"` in helm_release |
| Load generator pod Pending | t3.small nodes full (~11 pod limit), monitoring stack consumed all slots | Ran load test from inside existing pod via `kubectl exec` |
| kubectl hitting AKS instead of EKS | Running EKS and AKS simultaneously — kubeconfig context switches | Always use `--context arn:aws:eks:us-east-1:259851212818:cluster/demo-dev-eks` |
| RDS `FreeTierRestrictionError` | `backup_retention_period = 7` exceeds free tier max of 1 day | Set `backup_retention_period = 1` for free tier |
| CloudTrail missing `s3_bucket_name` | Required argument omitted; `aws_cloudtrail_event_selector` deprecated in v5 | Added dedicated S3 bucket + policy; moved `event_selector` inline |
| tflint missed syntax errors | `continue-on-error: true` silently ignored issues; no AWS plugin configured | Created `.tflint.hcl` with AWS ruleset; removed `continue-on-error` from CI |
| `terraform force-unlock` hung CI | Command waited for interactive confirmation | Added `timeout 60` + `-force` flag + GitHub `timeout-minutes: 2` |
| Prometheus `helm_release` failed with `context deadline exceeded` | Default Helm wait timeout is 5 min; kube-prometheus-stack is slower on small nodes | `timeout = 900` on the release |
| CI failed: "repository does not exist" on a fresh stack | CI and Terraform Apply ran in parallel; ECR is created by Terraform | CI also triggers (`workflow_run`) after a successful Terraform Apply |
| App did not come up after a rebuild | ArgoCD Applications were applied by hand, not by Terraform | `helm_release.argocd_apps` (argocd-apps chart) creates them |
| External Secrets pod Pending, Helm timed out | t3.small holds ~11 pods; 3 nodes were full and the autoscaler max was 3 | Node group `max_size = 5`; `ignore_changes` on `desired_size` so the autoscaler owns node count |
| Pods could not reach RDS | Standalone `aws_vpc_security_group_ingress_rule` was stripped by the SG's authoritative inline `ingress` block | One inline rule with both source SGs (`concat([ec2_sg], extra_sgs)`) |
| Frontend showed "API unreachable" via port-forward | Port-forwarding the frontend pod bypasses ingress; only ingress routes `/api` to the API | Use the load balancer URL (or port-forward `ingress-nginx-controller`) |
| `terraform destroy` hung on the External Secrets release | An `ExternalSecret` finalizer needs the controller, which Terraform removed first | Clear the finalizer, force-delete the controller pods, re-run destroy (proper fix: destroy ordering) |

---

## Cost Notes

- Measured burn while running: roughly $0.50/hour (~$12/day) — EKS control plane, 3–4 t3.small nodes, NAT gateway, RDS, load balancer, data transfer
- OIDC provider + IAM roles = free (permanent, always live in bootstrap state)
- Cluster destroyed after each session to avoid idle costs
- Infracost PR check shows cost delta on every terraform PR
- Potential saving: switch `t3.small` → `t4g.small` (ARM Graviton, ~20% cheaper)
- **Free tier constraints**: RDS backup retention limited to 1 day (not 7+)
- **Free tier friendly**: Uses AWS-managed KMS key (no $1/month custom key)
- CloudTrail S3 logs = ~$0.03/GB/month (auto-cleanup with lifecycle rules recommended)
