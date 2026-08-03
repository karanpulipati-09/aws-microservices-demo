variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "admin_iam_arn" {
  type        = string
  description = "IAM user/role ARN to grant EKS cluster admin access"
}

variable "gha_role_arn" {
  type        = string
  description = "GitHub Actions IAM role ARN to grant EKS cluster admin access for deployments"
}
