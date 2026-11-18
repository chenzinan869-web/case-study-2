# Grafana is stateless: its database is on RDS and its alerts and dashboard come from S3.
resource "aws_s3_bucket" "config" {
  bucket = "innovatech-config-${random_id.suffix.hex}"
}
resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "grafana_alerting" {
  bucket = aws_s3_bucket.config.id
  key    = "grafana/alerting.yaml"
  source = "${path.module}/grafana/alerting.yaml"
  etag   = filemd5("${path.module}/grafana/alerting.yaml")
}
resource "aws_s3_object" "grafana_dashboard" {
  bucket = aws_s3_bucket.config.id
  key    = "grafana/dashboard-soar.json"
  source = "${path.module}/grafana/dashboard-soar.json"
  etag   = filemd5("${path.module}/grafana/dashboard-soar.json")
}

locals {
  grafana_config_hash = md5("${filemd5("${path.module}/grafana/alerting.yaml")}${filemd5("${path.module}/grafana/dashboard-soar.json")}")
}

resource "aws_network_interface" "grafana" {
  subnet_id       = aws_subnet.monitoring[0].id
  private_ips     = ["10.20.10.104"]
  security_groups = [aws_security_group.monitoring.id]
  tags            = { Name = "grafana-eni" }
}

resource "aws_launch_template" "grafana" {
  name_prefix   = "grafana-"
  image_id      = data.aws_ssm_parameter.ubuntu.value
  instance_type = var.instance_type_small
  key_name      = aws_key_pair.ansible.key_name

  network_interfaces {
    device_index         = 0
    network_interface_id = aws_network_interface.grafana.id
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }
  metadata_options {
    http_tokens = "required"
  }
  user_data = base64encode(templatefile("${path.module}/grafana_user_data.sh.tftpl", {
    region          = var.region
    config_bucket   = aws_s3_bucket.config.id
    config_hash     = local.grafana_config_hash
    db_host         = aws_db_instance.postgres.address
    db_secret_arn   = aws_db_instance.postgres.master_user_secret[0].secret_arn
    soar_secret_arn = aws_secretsmanager_secret.soar_app.arn
    loki_url        = "http://loki.${var.internal_domain}:3100"
    prometheus_url  = "http://prometheus.${var.internal_domain}:9090"
  }))
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "grafana", Role = "grafana" }
  }
}

resource "aws_autoscaling_group" "grafana" {
  name                = "grafana-asg"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  availability_zones  = [aws_subnet.monitoring[0].availability_zone]
  health_check_type   = "EC2"
  launch_template {
    id      = aws_launch_template.grafana.id
    version = aws_launch_template.grafana.latest_version
  }
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }
  depends_on = [aws_s3_object.grafana_alerting, aws_s3_object.grafana_dashboard]
}
