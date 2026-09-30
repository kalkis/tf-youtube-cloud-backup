variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "name_prefix" {
  description = "Prefix for resource names. Must match the bootstrap root so the ECR repositories are found."
  type        = string
  default     = "ytbackup"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,31}$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits and hyphens, starting with a letter, at most 32 characters."
  }
}

variable "channel_ids" {
  description = "Channels to follow. Seeds the channel list parameter on the first apply only; afterwards the subscribe and unsubscribe actions own it."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.channel_ids : can(regex("^UC[A-Za-z0-9_-]{22}$", c))])
    error_message = "Each channel ID must match ^UC[A-Za-z0-9_-]{22}$."
  }
}

variable "retention_days" {
  description = "Days to keep each item after its last fetch. YouTube's policy caps stored API data at 30 days, and DynamoDB TTL deletes can lag by a few days, so keep a margin."
  type        = number
  default     = 28

  validation {
    condition     = var.retention_days >= 1 && floor(var.retention_days) == var.retention_days
    error_message = "retention_days must be a whole number of at least 1."
  }
}

variable "max_receive_count" {
  description = "Receives before a message moves to the DLQ."
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 1 && var.max_receive_count <= 1000 && floor(var.max_receive_count) == var.max_receive_count
    error_message = "max_receive_count must be a whole number from 1 to 1000."
  }
}

variable "api_key_secret_name" {
  description = "Name of the Secrets Manager secret holding the YouTube API key in its API_KEY field. Created outside Terraform."
  type        = string
}

variable "hub_secret_version" {
  description = "Increase to rotate the hub HMAC secret."
  type        = number
  default     = 1

  validation {
    condition     = var.hub_secret_version >= 1 && floor(var.hub_secret_version) == var.hub_secret_version
    error_message = "hub_secret_version must be a whole number of at least 1."
  }
}

variable "lease_seconds" {
  type    = number
  default = 432000

  validation {
    condition     = var.lease_seconds >= 1 && floor(var.lease_seconds) == var.lease_seconds
    error_message = "lease_seconds must be a whole number of at least 1."
  }
}

variable "resubscribe_interval" {
  description = "EventBridge Scheduler expression. Keep it shorter than lease_seconds."
  type        = string
  default     = "rate(4 days)"
}

variable "callback_reserved_concurrency" {
  type    = number
  default = null

  validation {
    condition     = var.callback_reserved_concurrency == null || (var.callback_reserved_concurrency >= 0 && floor(var.callback_reserved_concurrency) == var.callback_reserved_concurrency)
    error_message = "callback_reserved_concurrency must be null or a whole number of at least 0."
  }
}

variable "collector_max_concurrency" {
  type    = number
  default = 2

  validation {
    condition     = var.collector_max_concurrency >= 2 && var.collector_max_concurrency <= 1000 && floor(var.collector_max_concurrency) == var.collector_max_concurrency
    error_message = "collector_max_concurrency must be a whole number from 2 to 1000."
  }
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "alert_email" {
  description = "Email address for alarm notifications, or null for alarms with no action."
  type        = string
  default     = null

  validation {
    condition     = var.alert_email == null || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be null or a valid email address."
  }
}
