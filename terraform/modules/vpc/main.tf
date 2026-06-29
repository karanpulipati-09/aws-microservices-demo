locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${local.name_prefix}-vpc"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway — allows public subnets to reach the internet
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${local.name_prefix}-igw"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Public Subnets — one per AZ, EC2 instances get public IPs here
# ALB will sit in these subnets
# -----------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name        = "${local.name_prefix}-public-subnet-${count.index + 1}"
    Environment = var.environment
    ManagedBy   = "terraform"
    Tier        = "public"
  }
}

# -----------------------------------------------------------------------------
# Private Subnets — one per AZ, app servers live here (no direct internet)
# -----------------------------------------------------------------------------

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name        = "${local.name_prefix}-private-subnet-${count.index + 1}"
    Environment = var.environment
    ManagedBy   = "terraform"
    Tier        = "private"
  }
}

# -----------------------------------------------------------------------------
# Database Subnets — isolated subnet tier for RDS, no route to internet
# -----------------------------------------------------------------------------

resource "aws_subnet" "database" {
  count = length(var.db_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.db_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name        = "${local.name_prefix}-db-subnet-${count.index + 1}"
    Environment = var.environment
    ManagedBy   = "terraform"
    Tier        = "database"
  }
}

# -----------------------------------------------------------------------------
# Elastic IP for NAT Gateway — static IP that private subnets use to reach internet
# -----------------------------------------------------------------------------

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name        = "${local.name_prefix}-nat-eip"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# NAT Gateway — sits in public subnet, lets private subnet EC2 reach internet
# (for package installs, pulling Docker images etc.) without being publicly reachable
# -----------------------------------------------------------------------------

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name        = "${local.name_prefix}-nat"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# Route Tables
# -----------------------------------------------------------------------------

# Public route table — all internet traffic goes through IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "${local.name_prefix}-public-rt"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Private route table — internet traffic goes through NAT gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name        = "${local.name_prefix}-private-rt"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Database route table — no internet route, completely isolated
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${local.name_prefix}-db-rt"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Route Table Associations — connect each subnet to its route table
# -----------------------------------------------------------------------------

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "database" {
  count          = length(aws_subnet.database)
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}
