resource "aws_sns_topic" "videos" {
  name              = "${var.name_prefix}-videos"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-videos-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "videos" {
  name                       = "${var.name_prefix}-videos"
  visibility_timeout_seconds = 180
  message_retention_seconds  = 345600
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

data "aws_iam_policy_document" "queue" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.videos.arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.videos.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "videos" {
  queue_url = aws_sqs_queue.videos.id
  policy    = data.aws_iam_policy_document.queue.json
}

resource "aws_sns_topic_subscription" "videos" {
  topic_arn            = aws_sns_topic.videos.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.videos.arn
  raw_message_delivery = true
}
