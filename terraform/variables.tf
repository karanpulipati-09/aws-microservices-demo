variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS account ID for the deployment."
  type        = string
  default     = "259851212818"
}

variable "project_name" {
  description = "Project name used for naming all resources"
  type        = string
  default     = "demo"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "admin_iam_name" {
  description = "Local IAM user used for cluster admin access."
  type        = string
  default     = "terraform-learner"
}

variable "gha_role_name" {
  description = "GitHub Actions IAM role used for CI/CD."
  type        = string
  default     = "github-actions-terraform"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "alert_email" {
  description = "Optional email address to subscribe to alarm SNS topic"
  type        = string
  default     = ""
}

variable "tfstate_bucket" {
  description = "Terraform remote state bucket name to monitor for access"
  type        = string
}

