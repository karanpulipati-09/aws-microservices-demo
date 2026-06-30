variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to launch EC2 into"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for EC2"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID to attach to the EC2 instance (created by root to avoid circular deps)"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "AMI ID — leave empty to use latest Amazon Linux 2023"
  type        = string
  default     = ""
}
