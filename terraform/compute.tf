data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_key_pair" "ansible" {
  key_name   = "innovatech-ansible"
  public_key = var.ssh_public_key
}

# ---------- Loki + Prometheus (Subnet A) ----------
# Installs itself at first boot (user data), so no Ansible and no VPN are needed for this server.
resource "aws_instance" "loki_prometheus" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type_monitoring
  subnet_id              = aws_subnet.monitoring[0].id
  vpc_security_group_ids = [aws_security_group.monitoring.id]
  key_name               = aws_key_pair.ansible.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  user_data = templatefile("${path.module}/loki_prometheus_user_data.sh.tftpl", {
    region = var.region
    bucket = aws_s3_bucket.logs.id
    domain = var.internal_domain
  })
  user_data_replace_on_change = true
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # containers (Loki) must be able to reach the instance role
  }
  root_block_device {
    volume_size = 40
    encrypted   = true
  }
  tags = { Name = "loki-prometheus", Role = "monitoring_stack" }
}

# ---------- Grafana (EC2 Auto Scaling Group, Subnet A) ----------
resource "aws_launch_template" "grafana" {
  name_prefix            = "grafana-"
  image_id               = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type_small
  key_name               = aws_key_pair.ansible.key_name
  vpc_security_group_ids = [aws_security_group.monitoring.id]
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }
  metadata_options {
    http_tokens = "required"
  }
  user_data = base64encode(templatefile("${path.module}/grafana_user_data.sh.tftpl", {
    loki_url       = "http://loki.${var.internal_domain}:3100"
    prometheus_url = "http://prometheus.${var.internal_domain}:9090"
  }))
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "grafana", Role = "grafana" }
  }
}

resource "aws_autoscaling_group" "grafana" {
  name                = "grafana-asg"
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1
  vpc_zone_identifier = aws_subnet.monitoring[*].id
  health_check_type   = "EC2"
  launch_template {
    id      = aws_launch_template.grafana.id
    version = "$Latest"
  }
  instance_refresh {
    strategy = "Rolling"
  }
}

# ---------- NLB in front of the SOAR (Subnet B); the SOAR itself is ECS Fargate (ecs.tf) ----------
resource "aws_lb" "soar" {
  name               = "innovatech-soar-nlb"
  load_balancer_type = "network"
  internal           = true
  subnets            = aws_subnet.soar[*].id
}
resource "aws_lb_target_group" "soar" {
  name        = "soar-tg"
  port        = 8080
  protocol    = "TCP"
  target_type = "ip" # Fargate tasks register by IP
  vpc_id      = aws_vpc.main.id
  health_check {
    protocol = "HTTP"
    path     = "/health"
    port     = "8080"
  }
}
resource "aws_lb_listener" "soar" {
  load_balancer_arn = aws_lb.soar.arn
  port              = 8080
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.soar.arn
  }
}
