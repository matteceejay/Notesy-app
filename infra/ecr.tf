resource "aws_ecr_repository" "app" {
  name = var.app_name
  # Commit-SHA tags can never be overwritten; only the floating "latest" tag can move.
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"
  force_delete         = true # lets `terraform destroy` remove a repo that still has images

  image_tag_mutability_exclusion_filter {
    filter      = "latest"
    filter_type = "WILDCARD"
  }

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 30 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}
