resource "aws_security_group" "monitoring" {
  name        = "monitoring-sg"
  description = "Subnet A: Grafana, Loki, Prometheus"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Grafana from on-prem"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.onprem_cidr]
  }
  ingress {
    description = "Loki from on-prem (Alloy)"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = [var.onprem_cidr]
  }
  ingress {
    description = "Prometheus from on-prem (Alloy remote_write)"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.onprem_cidr]
  }
  ingress {
    description = "Grafana to Loki and Prometheus inside the SG"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }
  ingress {
    description = "SSH from Ansible node"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.onprem_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "soar" {
  name        = "soar-sg"
  description = "Subnet B: SOAR Fargate tasks behind the NLB (no SSH, no servers)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Webhook from on-prem, NLB health checks and Prometheus /metrics (VPC)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.onprem_cidr, var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# "5432 from A and B"
resource "aws_security_group" "db" {
  name        = "db-sg"
  description = "Subnet C: PostgreSQL only from monitoring and SOAR"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id, aws_security_group.soar.id]
  }
}
