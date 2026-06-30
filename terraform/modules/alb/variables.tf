variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for the ALB"
  type        = list(string)
}

variable "ec2_instance_id" {
  description = "EC2 instance ID to register in the target group"
  type        = string
}

variable "ec2_security_group_id" {
  description = "EC2 SG ID — passed through to outputs so root can wire SG rules"
  type        = string
}

variable "alb_security_group_id" {
  description = "ALB SG ID — created at root to avoid circular dep, passed in here"
  type        = string
}
