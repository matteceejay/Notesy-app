output "app_url" {
  value = "http://${aws_lb.app.dns_name}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "db_endpoint" {
  value = aws_db_instance.main.address
}

output "app_secret_arn" {
  description = "Put real SUMMARIZER_* values here."
  value       = aws_secretsmanager_secret.app.arn
}

# Copy these into GitHub: Settings -> Secrets and variables -> Actions -> Variables
output "github_actions_variables" {
  value = {
    AWS_ROLE_ARN    = aws_iam_role.github_deploy.arn
    AWS_REGION      = var.aws_region
    ECR_REPOSITORY  = aws_ecr_repository.app.name
    ECS_CLUSTER     = aws_ecs_cluster.main.name
    ECS_SERVICE     = aws_ecs_service.app.name
    ECS_TASK_FAMILY = aws_ecs_task_definition.app.family
    CONTAINER_NAME  = local.container_name
  }
}
