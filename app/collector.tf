locals {
  collector = "${var.name_prefix}-collector"
}

resource "aws_cloudwatch_log_group" "collector" {
  name              = "/aws/lambda/${local.collector}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "collector" {
  name               = local.collector
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "collector_logs" {
  role       = aws_iam_role.collector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "collector" {
  statement {
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.videos.arn]
  }

  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.videos.arn]
  }

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.api_key.arn]
  }
}

resource "aws_iam_role_policy" "collector" {
  name   = "collector"
  role   = aws_iam_role.collector.id
  policy = data.aws_iam_policy_document.collector.json
}

resource "aws_lambda_function" "collector" {
  function_name = local.collector
  role          = aws_iam_role.collector.arn
  package_type  = "Image"
  image_uri     = "${data.aws_ecr_repository.app["collector"].repository_url}:latest"
  architectures = ["x86_64"]
  memory_size   = 256
  timeout       = 30

  environment {
    variables = {
      TABLE_NAME        = aws_dynamodb_table.videos.name
      API_KEY_SECRET_ID = data.aws_secretsmanager_secret.api_key.arn
      RETENTION_DAYS    = tostring(var.retention_days)
    }
  }

  logging_config {
    log_format = "JSON"
  }

  depends_on = [
    aws_cloudwatch_log_group.collector,
    aws_iam_role_policy.collector,
    aws_iam_role_policy_attachment.collector_logs,
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_lambda_event_source_mapping" "collector" {
  event_source_arn        = aws_sqs_queue.videos.arn
  function_name           = aws_lambda_function.collector.arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = var.collector_max_concurrency
  }
}
