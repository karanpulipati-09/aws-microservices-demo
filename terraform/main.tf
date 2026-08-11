module "vpc" {
  source = "./modules/vpc"

  project_name = var.project_name
  environment  = var.environment
  vpc_cidr     = var.vpc_cidr
}

# Security groups created at root to break the ALB ↔ EC2 circular dependency.
# ALB SG needs to reference EC2 SG (egress), and EC2 SG needs to reference ALB SG (ingress).
# Terraform can resolve this only when both are in the same scope.

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-${var.environment}-ec2-sg"
  description = "Allow HTTP from ALB only"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name        = "${var.project_name}-${var.environment}-ec2-sg"
    Environment = var.environment
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-alb-sg"
  description = "Allow HTTP from internet"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name        = "${var.project_name}-${var.environment}-alb-sg"
    Environment = var.environment
  }
}

resource "aws_security_group_rule" "alb_ingress_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "HTTP from internet"
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_egress_to_ec2" {
  type                     = "egress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2.id
  description              = "HTTP to EC2 only"
  security_group_id        = aws_security_group.alb.id
}

resource "aws_security_group_rule" "ec2_ingress_from_alb" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  description              = "HTTP from ALB only"
  security_group_id        = aws_security_group.ec2.id
}

resource "aws_security_group_rule" "ec2_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "All outbound (for NAT gateway to reach internet)"
  security_group_id = aws_security_group.ec2.id
}

module "ec2" {
  source = "./modules/ec2"

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  security_group_id  = aws_security_group.ec2.id
  instance_type      = var.instance_type
}

module "alb" {
  source = "./modules/alb"

  project_name          = var.project_name
  environment           = var.environment
  vpc_id                = module.vpc.vpc_id
  public_subnet_ids     = module.vpc.public_subnet_ids
  ec2_instance_id       = module.ec2.instance_id
  ec2_security_group_id = aws_security_group.ec2.id
  alb_security_group_id = aws_security_group.alb.id
}

resource "random_password" "db" {
  length  = 16
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project_name}-${var.environment}-db-password"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = random_password.db.result
}

module "rds" {
  source = "./modules/rds"

  project_name          = var.project_name
  environment           = var.environment
  vpc_id                = module.vpc.vpc_id
  db_subnet_ids         = module.vpc.database_subnet_ids
  ec2_security_group_id = aws_security_group.ec2.id
  db_password           = random_password.db.result
}

module "eks" {
  source = "./modules/eks"

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  admin_iam_arn      = "arn:aws:iam::259851212818:user/terraform-learner"
  gha_role_arn       = "arn:aws:iam::259851212818:role/github-actions-terraform"
}

module "ecr" {
  source = "./modules/ecr"

  repositories = ["frontend", "api"]
  environment  = var.environment
}

# ingress-nginx — installed into the cluster automatically on every fresh apply
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = "4.11.3"

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  depends_on = [module.eks]
}

# dev namespace — managed by Terraform so RBAC resources have a target
resource "kubernetes_namespace" "dev" {
  metadata {
    name = "dev"
  }
  depends_on = [module.eks]
}

# gp3 StorageClass — default class for PVCs (postgres etc.)
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type = "gp3"
  }
  depends_on = [module.eks]
}

# RBAC — dev-readonly: read-only access to dev namespace
resource "kubernetes_service_account" "dev_readonly" {
  metadata {
    name      = "dev-readonly"
    namespace = kubernetes_namespace.dev.metadata[0].name
  }
}

resource "kubernetes_role" "dev_readonly" {
  metadata {
    name      = "dev-readonly"
    namespace = kubernetes_namespace.dev.metadata[0].name
  }
  rule {
    api_groups = ["", "apps"]
    resources  = ["pods", "services", "endpoints", "configmaps", "deployments", "replicasets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "dev_readonly" {
  metadata {
    name      = "dev-readonly"
    namespace = kubernetes_namespace.dev.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.dev_readonly.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.dev_readonly.metadata[0].name
    namespace = kubernetes_namespace.dev.metadata[0].name
  }
}

# RBAC — dev-admin: full access to dev namespace
resource "kubernetes_service_account" "dev_admin" {
  metadata {
    name      = "dev-admin"
    namespace = kubernetes_namespace.dev.metadata[0].name
  }
}

resource "kubernetes_role" "dev_admin" {
  metadata {
    name      = "dev-admin"
    namespace = kubernetes_namespace.dev.metadata[0].name
  }
  rule {
    api_groups = ["", "apps", "batch"]
    resources  = ["*"]
    verbs      = ["*"]
  }
}

resource "kubernetes_role_binding" "dev_admin" {
  metadata {
    name      = "dev-admin"
    namespace = kubernetes_namespace.dev.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.dev_admin.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.dev_admin.metadata[0].name
    namespace = kubernetes_namespace.dev.metadata[0].name
  }
}

# Cluster Autoscaler — watches Pending pods and scales ASG nodes up/down
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = "9.43.2"

  set {
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "awsRegion"
    value = var.aws_region
  }

  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }

  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.cluster_autoscaler_role_arn
  }

  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }

  set {
    name  = "extraArgs.skip-nodes-with-system-pods"
    value = "false"
  }

  depends_on = [module.eks]
}

# metrics-server — required for HPA to read CPU/memory metrics
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.1"

  depends_on = [module.eks]
}

# Grafana admin password — generated, retrieve with: terraform output -raw grafana_admin_password
resource "random_password" "grafana" {
  length  = 16
  special = false
}

# kube-prometheus-stack — Prometheus + Grafana in one chart
resource "helm_release" "prometheus" {
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  version          = "61.3.2"

  set {
    name  = "grafana.adminPassword"
    value = random_password.grafana.result
  }

  # disable alertmanager to reduce memory pressure on t3.small nodes
  set {
    name  = "alertmanager.enabled"
    value = "false"
  }

  # scrape all namespaces, not just ones with helm labels
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  depends_on = [module.eks]
}

# ArgoCD — GitOps controller, watches Git repo and syncs Helm charts to cluster
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "7.4.4"

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  depends_on = [module.eks]
}

# OIDC + IAM role live in bootstrap/ state — never destroyed with infra
