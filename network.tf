data "aws_availability_zones" "available" { state = "available" }

locals {
  azs              = slice(data.aws_availability_zones.available.names, 0, 2) # REQ-02: two AZs
  public_cidrs     = ["10.20.0.0/24", "10.20.1.0/24"]
  monitoring_cidrs = ["10.20.10.0/24", "10.20.11.0/24"] # Subnet A
  soar_cidrs       = ["10.20.20.0/24", "10.20.21.0/24"] # Subnet B
  db_cidrs         = ["10.20.30.0/24", "10.20.31.0/24"] # Subnet C
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "innovatech-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "public-${count.index}" }
}
resource "aws_subnet" "monitoring" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.monitoring_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "subnet-a-monitoring-${count.index}" }
}
resource "aws_subnet" "soar" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.soar_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "subnet-b-soar-${count.index}" }
}
resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.db_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "subnet-c-db-${count.index}" }
}

# One NAT gateway so private instances can install packages (cheaper, single point of failure)
resource "aws_eip" "nat" {
  domain = "vpc"
}
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}
resource "aws_route_table_association" "monitoring" {
  count          = 2
  subnet_id      = aws_subnet.monitoring[count.index].id
  route_table_id = aws_route_table.private.id
}
resource "aws_route_table_association" "soar" {
  count          = 2
  subnet_id      = aws_subnet.soar[count.index].id
  route_table_id = aws_route_table.private.id
}
resource "aws_route_table_association" "db" {
  count          = 2
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.private.id
}

# "S3 endpoint (logs)" in the diagram
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

# REQ-04: Route 53 private hosted zone
resource "aws_route53_zone" "internal" {
  name = var.internal_domain
  vpc {
    vpc_id = aws_vpc.main.id
  }
}
resource "aws_route53_record" "loki" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "loki.${var.internal_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.loki_prometheus.private_ip]
}
resource "aws_route53_record" "prometheus" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "prometheus.${var.internal_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.loki_prometheus.private_ip]
}
resource "aws_route53_record" "soar" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "soar.${var.internal_domain}"
  type    = "A"
  alias {
    name                   = aws_lb.soar.dns_name
    zone_id                = aws_lb.soar.zone_id
    evaluate_target_health = true
  }
}
resource "aws_route53_record" "db" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "db.${var.internal_domain}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_db_instance.postgres.address]
}
