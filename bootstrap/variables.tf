variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "name_prefix" {
  description = "Prefix for the ECR repositories, roles and Lambda function names."
  type        = string
  default     = "ytbackup"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,31}$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits and hyphens, starting with a letter, at most 32 characters."
  }
}

variable "github_owner" {
  description = "GitHub user or organisation that owns the app repositories. The deploy roles trust only workflows on main in <github_owner>/<repo>."
  type        = string
}

variable "callback_repo_name" {
  type    = string
  default = "youtube-notification-callback"
}

variable "collector_repo_name" {
  type    = string
  default = "youtube-metadata-collector"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider, or set to false to look up an existing one. It is never deleted by Terraform."
  type        = bool
  default     = true
}

variable "ecr_keep_images" {
  description = "Number of tagged images to keep in each ECR repository."
  type        = number
  default     = 10

  validation {
    condition     = var.ecr_keep_images >= 1 && floor(var.ecr_keep_images) == var.ecr_keep_images
    error_message = "ecr_keep_images must be a whole number of at least 1."
  }
}
