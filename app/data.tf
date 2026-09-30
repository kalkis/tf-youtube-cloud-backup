data "aws_ecr_repository" "app" {
  for_each = toset(["callback", "collector"])
  name     = "${var.name_prefix}-${each.key}"
}

data "aws_secretsmanager_secret" "api_key" {
  name = var.api_key_secret_name
}

data "aws_caller_identity" "current" {}
