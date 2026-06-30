output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.web.id
}

output "private_ip" {
  description = "EC2 private IP address"
  value       = aws_instance.web.private_ip
}
