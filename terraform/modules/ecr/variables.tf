variable "repositories" {
  description = "List of ECR repository names"
  type        = list(string)
}

variable "environment" {
  description = "Environment name"
  type        = string
}
