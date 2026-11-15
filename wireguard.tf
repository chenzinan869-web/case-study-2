# WireGuard tunnel between the on-premise network and the VPC (replaces the AWS Site-to-Site VPN).
# The server generates its own key pair at first boot, so no private key is stored in the Terraform state.
locals {
  onprem_sources = [var.onprem_cidr, "10.99.0.0/24"]
}

resource "aws_security_group" "wireguard" {
  name        = "wireguard-sg"
  description = "WireGuard server"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "WireGuard from the on-premise network"
    from_port   = var.wireguard_port
    to_port     = var.wireguard_port
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "Traffic from the VPC towards on-premise, forwarded by this server"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "wireguard" {
  name               = "innovatech-wireguard"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}
resource "aws_iam_role_policy_attachment" "wireguard_ssm" {
  role       = aws_iam_role.wireguard.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy" "wireguard_param" {
  name = "publish-server-public-key"
  role = aws_iam_role.wireguard.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:PutParameter"]
      Resource = [aws_ssm_parameter.wireguard_server_public_key.arn]
    }]
  })
}
resource "aws_iam_instance_profile" "wireguard" {
  name = "innovatech-wireguard"
  role = aws_iam_role.wireguard.name
}

resource "aws_ssm_parameter" "wireguard_server_public_key" {
  name  = "/innovatech/wireguard/server-public-key"
  type  = "String"
  value = "pending"
  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_instance" "wireguard" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.wireguard.id]
  iam_instance_profile   = aws_iam_instance_profile.wireguard.name
  source_dest_check      = false # this instance forwards traffic that is not addressed to itself
  user_data = templatefile("${path.module}/wireguard_user_data.sh.tftpl", {
    region            = var.region
    wg_port           = var.wireguard_port
    client_public_key = var.wireguard_client_public_key
    onprem_cidr       = var.onprem_cidr
  })
  user_data_replace_on_change = true
  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    encrypted = true
  }
  tags       = { Name = "wireguard", Role = "wireguard" }
  depends_on = [aws_ssm_parameter.wireguard_server_public_key]
}

resource "aws_eip" "wireguard" {
  domain     = "vpc"
  instance   = aws_instance.wireguard.id
  depends_on = [aws_internet_gateway.igw]
}

# Routes towards on-premise (and the tunnel network) go through the WireGuard server
resource "aws_route" "onprem" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = var.onprem_cidr
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}
resource "aws_route" "wireguard_net" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "10.99.0.0/24"
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}

# Design-for-failure: AWS recovers the instance (same disk, same Elastic IP) after a hardware failure
resource "aws_cloudwatch_metric_alarm" "wireguard_recover" {
  alarm_name          = "wireguard-system-check-failed"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    InstanceId = aws_instance.wireguard.id
  }
  alarm_actions = ["arn:aws:automate:${var.region}:ec2:recover"]
}