resource "aws_dynamodb_table" "videos" {
  name                        = "${var.name_prefix}-video-metadata"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "video_id"
  deletion_protection_enabled = false

  attribute {
    name = "video_id"
    type = "S"
  }

  attribute {
    name = "channel_id"
    type = "S"
  }

  attribute {
    name = "published_at"
    type = "S"
  }

  global_secondary_index {
    name            = "by_channel"
    projection_type = "ALL"

    key_schema {
      attribute_name = "channel_id"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "published_at"
      key_type       = "RANGE"
    }
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false
  }
}
