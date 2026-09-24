locals {
  container_name = var.app_name
  secret_arn     = aws_secretsmanager_secret.app.arn
}

resource "aws_ecs_cluster" "main" {
  name = "${var.app_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.app_name}"
  retention_in_days = var.log_retention_days
}

# Terraform creates the first revision. After that the pipeline fetches the latest
# revision, swaps the image, and registers a new one, so later changes you make here
# (env vars, CPU, ...) take effect on the next pipeline deploy or `terraform apply`.
resource "aws_ecs_task_definition" "app" {
  family                   = var.app_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # GitHub's ubuntu-latest runners build amd64 images
  }

  container_definitions = jsonencode([{
    name      = local.container_name
    image     = "${aws_ecr_repository.app.repository_url}:${var.bootstrap_image_tag}"
    essential = true

    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]

    # Run migrations before serving, same as docker-compose (minus the demo seed).
    command = [
      "sh", "-c",
      "python manage.py migrate --noinput && exec gunicorn notesy.wsgi:application --bind 0.0.0.0:${var.container_port} --workers 3 --access-logfile -"
    ]

    environment = [
      { name = "DJANGO_DEBUG", value = "False" },
      { name = "DJANGO_ALLOWED_HOSTS", value = "${aws_lb.app.dns_name},localhost,127.0.0.1" },
    ]

    secrets = [
      for key in ["DJANGO_SECRET_KEY", "DATABASE_URL", "SUMMARIZER_API_KEY", "SUMMARIZER_URL"] :
      { name = key, valueFrom = "${local.secret_arn}:${key}::" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name                              = "${var.app_name}-service"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.app.arn
  desired_count                     = var.desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 60
  enable_execute_command            = false

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = true # needed to reach ECR without a NAT gateway
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true # a deploy that never gets healthy rolls back to the previous revision
  }

  depends_on = [aws_lb_listener.http]

  # The pipeline owns which revision is running; don't let `terraform apply` roll it back.
  lifecycle {
    ignore_changes = [task_definition]
  }
}
