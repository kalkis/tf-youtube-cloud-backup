output "callback_function_url" {
  value = aws_lambda_function_url.callback.function_url
}

output "callback_function_name" {
  value = aws_lambda_function.callback.function_name
}

output "collector_function_name" {
  value = aws_lambda_function.collector.function_name
}

output "queue_url" {
  value = aws_sqs_queue.videos.url
}

output "table_name" {
  value = aws_dynamodb_table.videos.name
}

output "api_key_secret_arn" {
  value = data.aws_secretsmanager_secret.api_key.arn
}

output "channel_ids_parameter_name" {
  value = aws_ssm_parameter.channel_ids.name
}
