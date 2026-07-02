output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "alb_dns_name" {
  description = "ALB DNS name — open this in your browser to see the nginx page"
  value       = module.alb.alb_dns_name
}

output "ec2_private_ip" {
  description = "EC2 private IP (not directly reachable — traffic goes through ALB)"
  value       = module.ec2.private_ip
}

output "db_endpoint" {
  description = "RDS endpoint — EC2 connects to this"
  value       = module.rds.db_endpoint
}

output "db_secret_name" {
  description = "Secrets Manager secret name — retrieve password from here"
  value       = aws_secretsmanager_secret.db.name
}
