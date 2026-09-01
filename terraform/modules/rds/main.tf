locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

data "aws_caller_identity" "current" {}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Allow MySQL from EC2 only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.ec2_security_group_id]
  }

  tags = {
    Name        = "${local.name_prefix}-rds-sg"
    Environment = var.environment
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = var.db_subnet_ids

  tags = {
    Name        = "${local.name_prefix}-db-subnet-group"
    Environment = var.environment
  }
}

# KMS key for encrypting RDS storage and snapshots
resource "aws_kms_key" "rds" {
  description             = "KMS key for ${local.name_prefix} RDS encryption"
  deletion_window_in_days = 30

  tags = {
    Name        = "${local.name_prefix}-rds-kms"
    Environment = var.environment
  }
}

resource "aws_kms_key_policy" "rds" {
  key_id = aws_kms_key.rds.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "Enable IAM Root"
        Effect = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action = "kms:*"
        Resource = "*"
      },
      {
        Sid = "Allow RDS Service"
        Effect = "Allow"
        Principal = { Service = "rds.amazonaws.com" }
        Action = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_db_instance" "main" {
  identifier        = "${local.name_prefix}-mysql"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = var.instance_class
  allocated_storage = 20

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Backups & encryption
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.rds.arn
  copy_tags_to_snapshot   = true

  skip_final_snapshot = true
  publicly_accessible = false

  tags = {
    Name              = "${local.name_prefix}-mysql"
    Environment       = var.environment
    "weekly-snapshot" = "true"
  }
}
