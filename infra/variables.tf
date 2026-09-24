variable "aws_region" {
  description = "AWS region to deploy into (must match the AWS_REGION GitHub variable)."
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Name prefix for every resource."
  type        = string
  default     = "notesy"
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the deploy role, as owner/name."
  type        = string
  default     = "matteceejay/Notesy-app"
}

variable "create_github_oidc_provider" {
  description = "Only one GitHub OIDC provider may exist per AWS account. Set false if yours already has one."
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  deprecated = "cidr for the vpc."
  type    = string
  default = "10.20.0.0/16"
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "health_check_path" {
  description = "Must return 2xx/3xx without auth. /login/ renders the login page."
  type        = string
  default     = "/login/"
}

variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "bootstrap_image_tag" {
  description = "Image tag used for the very first task definition. The pipeline replaces it on every deploy."
  type        = string
  default     = "latest"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_deletion_protection" {
  description = "Turn on for anything you care about. Off by default so `terraform destroy` works for a lab."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  type    = number
  default = 14
}
