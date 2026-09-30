locals {
  callback           = "${var.name_prefix}-callback"
  callback_url_param = "/${var.name_prefix}/callback-url"
}

ephemeral "random_password" "hub_secret" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "hub_secret" {
  name             = "/${var.name_prefix}/hub-secret"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.hub_secret.result
  value_wo_version = var.hub_secret_version
}

resource "aws_ssm_parameter" "channel_ids" {
  name  = "/${var.name_prefix}/channel-ids"
  type  = "String"
  value = jsonencode(var.channel_ids)

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "callback_url" {
  name  = local.callback_url_param
  type  = "String"
  value = aws_lambda_function_url.callback.function_url
}

resource "aws_cloudwatch_log_group" "callback" {
  name              = "/aws/lambda/${local.callback}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "callback" {
  name               = local.callback
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "callback_logs" {
  role       = aws_iam_role.callback.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "callback" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.videos.arn]
  }

  statement {
    actions = ["ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.hub_secret.arn,
      aws_ssm_parameter.channel_ids.arn,
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.callback_url_param}",
    ]
  }

  statement {
    actions   = ["ssm:PutParameter"]
    resources = [aws_ssm_parameter.channel_ids.arn]
  }
}

resource "aws_iam_role_policy" "callback" {
  name   = "callback"
  role   = aws_iam_role.callback.id
  policy = data.aws_iam_policy_document.callback.json
}

resource "aws_lambda_function" "callback" {
  function_name                  = local.callback
  description                    = "Hub secret version ${var.hub_secret_version}"
  role                           = aws_iam_role.callback.arn
  package_type                   = "Image"
  image_uri                      = "${data.aws_ecr_repository.app["callback"].repository_url}:latest"
  architectures                  = ["x86_64"]
  memory_size                    = 256
  timeout                        = 15
  reserved_concurrent_executions = var.callback_reserved_concurrency

  environment {
    variables = {
      TOPIC_ARN          = aws_sns_topic.videos.arn
      HUB_SECRET_PARAM   = aws_ssm_parameter.hub_secret.name
      CHANNEL_IDS_PARAM  = aws_ssm_parameter.channel_ids.name
      CALLBACK_URL_PARAM = local.callback_url_param
      LEASE_SECONDS      = tostring(var.lease_seconds)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.callback,
    aws_iam_role_policy.callback,
    aws_iam_role_policy_attachment.callback_logs,
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_lambda_function_url" "callback" {
  function_name      = aws_lambda_function.callback.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "url" {
  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.callback.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "url_invoke" {
  statement_id             = "FunctionURLInvokeAllowPublicAccess"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.callback.function_name
  principal                = "*"
  invoked_via_function_url = true
}

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name_prefix}-resubscribe-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.callback.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "invoke-callback"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "resubscribe" {
  name                = "${var.name_prefix}-resubscribe"
  schedule_expression = var.resubscribe_interval

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.callback.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ action = "resubscribe" })
  }
}

action "aws_lambda_invoke" "resubscribe" {
  config {
    function_name = aws_lambda_function.callback.function_name
    payload       = jsonencode({ action = "resubscribe" })
  }
}

resource "terraform_data" "subscription" {
  input = var.hub_secret_version

  depends_on = [
    aws_lambda_function.callback,
    aws_lambda_function_url.callback,
    aws_lambda_permission.url,
    aws_lambda_permission.url_invoke,
    aws_ssm_parameter.callback_url,
  ]

  lifecycle {
    action_trigger {
      events     = [after_create, after_update]
      actions    = [action.aws_lambda_invoke.resubscribe]
      on_failure = continue
    }
  }
}
