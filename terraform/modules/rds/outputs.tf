output "db_endpoint" {
  description = "RDS endpoint — EC2 connects to this address"
  value       = aws_db_instance.main.endpoint
}

output "db_name" {
  description = "Database name"
  value       = aws_db_instance.main.db_name
}

output "security_group_id" {
  description = "RDS security group ID"
  value       = aws_security_group.rds.id
}

output "db_address" {
  description = "RDS hostname without port"
  value       = aws_db_instance.main.address
}

output "db_port" {
  value = aws_db_instance.main.port
}

output "db_username" {
  value = aws_db_instance.main.username
}
