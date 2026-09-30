output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "github_role_arns" {
  value = { for k, r in aws_iam_role.github : k => r.arn }
}

output "github_variables" {
  description = "Repository variables to set in each app repo, keyed by repo name."
  value = {
    for k, repo in local.repos : repo.name => {
      AWS_REGION           = var.region
      AWS_ROLE_ARN         = aws_iam_role.github[k].arn
      ECR_REPOSITORY       = aws_ecr_repository.app[k].name
      LAMBDA_FUNCTION_NAME = "${var.name_prefix}-${k}"
    }
  }
}
