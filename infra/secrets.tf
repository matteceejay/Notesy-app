# One JSON secret holding the app's sensitive config. ECS injects each key as an env var.
# The summarizer keys start as placeholders; set real values in the console or with
# `aws secretsmanager put-secret-value` (Terraform ignores later edits to them).

resource "random_password" "django_secret_key" {
  length  = 50
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.app_name}/app"
  recovery_window_in_days = 0 # allow immediate re-create after destroy; raise for production
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    DJANGO_SECRET_KEY  = random_password.django_secret_key.result
    DATABASE_URL       = "postgres://${aws_db_instance.main.username}:${random_password.db.result}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${aws_db_instance.main.db_name}"
    SUMMARIZER_API_KEY = "change-me"
    SUMMARIZER_URL     = "change-me"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
