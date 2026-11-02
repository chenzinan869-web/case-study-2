# ---------- SOAR as a container on ECS Fargate (PaaS: no servers to patch) ----------
resource "aws_ecr_repository" "soar" {
  name         = "innovatech/soar"
  force_delete = true
  image_scanning_configuration {
    scan_on_push = true
  }
}
resource "aws_ecr_lifecycle_policy" "soar" {
  repository = aws_ecr_repository.soar.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "soar" {
  name              = "/ecs/soar"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "main" {
  name = "innovatech"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# Secrets that the container receives as environment variables
resource "aws_secretsmanager_secret" "soar_app" {
  name                    = "innovatech/soar-app"
  recovery_window_in_days = 0
}
resource "aws_secretsmanager_secret_version" "soar_app" {
  secret_id = aws_secretsmanager_secret.soar_app.id
  secret_string = jsonencode({
    webhook_token  = var.soar_webhook_token
    kibana_api_key = var.kibana_api_key
  })
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: lets ECS pull the image, write logs and inject the secrets
resource "aws_iam_role" "soar_execution" {
  name               = "innovatech-soar-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}
resource "aws_iam_role_policy_attachment" "soar_execution" {
  role       = aws_iam_role.soar_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role_policy" "soar_execution_secrets" {
  name = "read-soar-app-secret"
  role = aws_iam_role.soar_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.soar_app.arn]
    }]
  })
}

# Task role: what the application itself may do (read the database password)
resource "aws_iam_role" "soar_task" {
  name               = "innovatech-soar-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}
resource "aws_iam_role_policy" "soar_task" {
  name = "read-db-secret"
  role = aws_iam_role.soar_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_db_instance.postgres.master_user_secret[0].secret_arn]
    }]
  })
}

resource "aws_ecs_task_definition" "soar" {
  family                   = "soar"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.soar_execution.arn
  task_role_arn            = aws_iam_role.soar_task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name         = "soar"
    image        = "${aws_ecr_repository.soar.repository_url}:latest"
    essential    = true
    portMappings = [{ containerPort = 8080, protocol = "tcp" }]
    environment = [
      { name = "AWS_REGION", value = var.region },
      { name = "DB_HOST", value = aws_db_instance.postgres.address },
      { name = "DB_NAME", value = "soar" },
      { name = "DB_SECRET_ARN", value = aws_db_instance.postgres.master_user_secret[0].secret_arn },
      { name = "KIBANA_URL", value = var.kibana_url },
    ]
    secrets = [
      { name = "WEBHOOK_TOKEN", valueFrom = "${aws_secretsmanager_secret.soar_app.arn}:webhook_token::" },
      { name = "KIBANA_API_KEY", valueFrom = "${aws_secretsmanager_secret.soar_app.arn}:kibana_api_key::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.soar.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "soar"
      }
    }
  }])
}

# Private DNS name that returns the IP of every running task, so Prometheus scrapes each task
resource "aws_service_discovery_private_dns_namespace" "svc" {
  name = "svc.${var.internal_domain}"
  vpc  = aws_vpc.main.id
}
resource "aws_service_discovery_service" "soar" {
  name = "soar"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.svc.id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

resource "aws_ecs_service" "soar" {
  name                              = "soar"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.soar.arn
  desired_count                     = var.soar_min_tasks
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = aws_subnet.soar[*].id # both AZs
    security_groups  = [aws_security_group.soar.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.soar.arn
    container_name   = "soar"
    container_port   = 8080
  }
  service_registries {
    registry_arn = aws_service_discovery_service.soar.arn
  }
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  depends_on = [aws_lb_listener.soar]
  lifecycle {
    ignore_changes = [desired_count] # autoscaling owns this value
  }
}

# Scalability: add tasks when CPU is high
resource "aws_appautoscaling_target" "soar" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.soar.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.soar_min_tasks
  max_capacity       = var.soar_max_tasks
}
resource "aws_appautoscaling_policy" "soar_cpu" {
  name               = "soar-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.soar.service_namespace
  resource_id        = aws_appautoscaling_target.soar.resource_id
  scalable_dimension = aws_appautoscaling_target.soar.scalable_dimension
  target_tracking_scaling_policy_configuration {
    target_value = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
