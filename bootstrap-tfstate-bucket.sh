#!/usr/bin/env bash
# Must match the bucket/region in backend.hcl. Requires an AWS CLI recent
# enough to support --bucket-namespace (account regional namespace).
#
# Optional environment overrides:
#   REGION         AWS region (default: eu-west-1)
#   ACCOUNT_ID     AWS account ID (default: account of the current credentials)
#   BUCKET_PREFIX  bucket name prefix (default: youtube-cloud-backup-tfstate)
set -euo pipefail

export AWS_DEFAULT_OUTPUT=json
export AWS_PAGER=""

REGION="${REGION:-eu-west-1}"
export AWS_REGION="$REGION"

if [[ -z "${ACCOUNT_ID:-}" ]]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
fi

BUCKET_PREFIX="${BUCKET_PREFIX:-youtube-cloud-backup-tfstate}"
BUCKET="${BUCKET_PREFIX}-${ACCOUNT_ID}-${REGION}-an"

# 1. Create the bucket in the account regional namespace, if it doesn't exist
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
  echo "Bucket $BUCKET already exists, skipping creation."
else
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --bucket-namespace account-regional \
    --create-bucket-configuration LocationConstraint="$REGION"
fi

# 2. Versioning
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

# 3. Block all public access
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 4. Disable ACLs
aws s3api put-bucket-ownership-controls \
  --bucket "$BUCKET" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

# 5. Default encryption (SSE-S3)
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# 6. Deny non-TLS requests
aws s3api put-bucket-policy \
  --bucket "$BUCKET" \
  --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"DenyInsecureTransport\",
      \"Effect\": \"Deny\",
      \"Principal\": \"*\",
      \"Action\": \"s3:*\",
      \"Resource\": [\"arn:aws:s3:::$BUCKET\", \"arn:aws:s3:::$BUCKET/*\"],
      \"Condition\": {\"Bool\": {\"aws:SecureTransport\": \"false\"}}
    }]
  }"

# 7. Lifecycle: expire old state versions and clean up failed uploads
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "tfstate-housekeeping",
      "Status": "Enabled",
      "Filter": {},
      "NoncurrentVersionExpiration": {"NoncurrentDays": 90, "NewerNoncurrentVersions": 10},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
    }]
  }'

echo "Bucket $BUCKET ready in $REGION."
