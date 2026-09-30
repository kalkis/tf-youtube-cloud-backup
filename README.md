# tf-youtube-cloud-backup

Terraform for the YouTube metadata collector: [`youtube-notification-callback`](https://github.com/kalkis/youtube-notification-callback) receives YouTube hub notifications and [`youtube-metadata-collector`](https://github.com/kalkis/youtube-metadata-collector) stores each video's metadata from the YouTube Data API v3 in DynamoDB, with a TTL.

```
YouTube hub → callback Lambda (Function URL) → SNS → SQS (raw delivery) → collector Lambda → YouTube Data API → DynamoDB
                    ▲ EventBridge Scheduler (resubscribe)      └→ DLQ → CloudWatch alarm → email (optional)
```

Scope is metadata only. Nothing downloads videos, thumbnails or captions, or scrapes YouTube.

## Layout

There are two root configurations, each with its own state file, deployed separately:

| Root         | Contents                                                                                                                                                                                  |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bootstrap/` | ECR repositories (`<prefix>-callback`, `<prefix>-collector`) with lifecycle policies, the GitHub OIDC provider, and one deploy role per app repo. Needed before any image can be pushed. |
| `app/`       | Everything else: SNS topic, SQS queue and DLQ, both Lambdas, the Function URL, the resubscribe schedule, SSM parameters, the DynamoDB table and the alarms. Disposable.                   |

`bootstrap-tfstate-bucket.sh` creates the S3 state bucket. Everything runs in `eu-west-1` by default, and neither Lambda runs in a VPC.

## Requirements

- Terraform `>= 1.16` (write-only arguments, actions, `on_failure` and `lifecycle { destroy = false }`)
- AWS CLI with credentials for the target account, the [GitHub CLI](https://cli.github.com/) and `jq`
- A Google Cloud project with the YouTube Data API v3 enabled and an **API key restricted to that API**. An IP restriction isn't possible, because Lambda's outbound IPs vary.

## Configuration

### Backend

Each root's `backend.tf` is just `terraform { backend "s3" {} }`, and the settings come from a partial configuration at init. Create the state bucket once, then write a `backend.hcl` with its name (git ignores `backend.hcl`):

```sh
./bootstrap-tfstate-bucket.sh   # prints the bucket name
```

```hcl
bucket       = "<state-bucket-name>"
region       = "eu-west-1"
encrypt      = true
use_lockfile = true   # S3-native locking, no DynamoDB table
```

Each root sets its own `key` at init, since later `-backend-config` values win. With `backend.hcl` one level above this repo:

```sh
terraform init -backend-config=../../backend.hcl -backend-config="key=youtube-backup/bootstrap.tfstate"  # from bootstrap/
terraform init -backend-config=../../backend.hcl -backend-config="key=youtube-backup/app.tfstate"        # from app/
```

Alternatively, copy each root's `backend.hcl.example` to `backend.hcl`, which already has the right `key`, and run `terraform init -backend-config=backend.hcl`.

### Variables

Copy each root's `terraform.tfvars.example` to `terraform.tfvars` (also ignored by git) and fill it in.

**`bootstrap/`**

| Variable                                     | Default                                                        | Notes                                                                                                                                  |
| -------------------------------------------- | -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `github_owner`                               | **none, required**                                             | GitHub user or organisation that owns the app repos                                                                                    |
| `github_owner_id`                            | **none, required**                                             | `gh api users/<github_owner> --jq .id`                                                                                                 |
| `callback_repo_id`, `collector_repo_id`      | **none, required**                                             | `gh api repos/<github_owner>/<repo> --jq .id`                                                                                          |
| `callback_repo_name`, `collector_repo_name`  | `youtube-notification-callback`, `youtube-metadata-collector` | Change only if your repos have other names                                                                                             |
| `name_prefix`                                | `ytbackup`                                                     | Prefix for repositories, roles and function names. Must match `app/`.                                                                 |
| `region`                                     | `eu-west-1`                                                    |                                                                                                                                        |
| `create_github_oidc_provider`                | `true`                                                         | Set to `false` if the account already has a GitHub OIDC provider (an account can have only one); it is then looked up instead         |
| `ecr_keep_images`                            | `10`                                                           | Tagged images kept per repository. Untagged images expire after 1 day.                                                                |

`github_owner`, `github_owner_id` and the two repo IDs have no defaults and must be set. Each deploy role trusts only workflows on `main` of its own repo, matched by GitHub's immutable OIDC subject claim:

```
repo:<github_owner>@<github_owner_id>/<repo_name>@<repo_id>:ref:refs/heads/main
```

Because the claim includes the numeric IDs, a renamed, deleted or re-registered owner or repo name can't assume the role.

- **Deploying from your own forks:** set `github_owner` and `github_owner_id` to your own GitHub user or organisation, and the two repo IDs to your forks' IDs, so the deploy roles trust your forks rather than the upstream repos. Set the repo names too if you renamed the forks.
- **Repos created before 2026-07-15** send the older name-only claim (`repo:<owner>/<repo>:...`) unless they opt in to immutable subject claims, and until they do, `AssumeRoleWithWebIdentity` fails in the release workflow. Newer repos use the immutable claim by default. Check a repo, and opt it in if needed:

  ```sh
  gh api repos/<owner>/<repo>/actions/oidc/customization/sub   # sub_claim_prefix must contain @<id>
  gh api -X PUT repos/<owner>/<repo>/actions/oidc/customization/sub -F use_default=true -F use_immutable_subject=true
  ```

**`app/`**

| Variable                        | Default            | Notes                                                                                                                                                                         |
| ------------------------------- | ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `api_key_secret_name`           | **none, required** | Secrets Manager secret holding the API key (`youtube-data-api` in the example)                                                                                              |
| `channel_ids`                   | `[]`               | Channels to follow. Seeds the channel list on the **first apply only**; afterwards the callback's invoke actions own it and Terraform ignores changes here.                 |
| `retention_days`                | `28`               | Days an item is kept after its last fetch. YouTube's policy caps stored API data at 30 days, and TTL deletes can lag by a few days, so keep a margin.                        |
| `max_receive_count`             | `5`                | Receives before a message moves to the DLQ                                                                                                                                   |
| `hub_secret_version`            | `1`                | Increase to rotate the hub HMAC secret                                                                                                                                       |
| `lease_seconds`                 | `432000` (5 days)  | Requested hub subscription lease                                                                                                                                              |
| `resubscribe_interval`          | `rate(4 days)`     | EventBridge Scheduler expression. Keep it shorter than `lease_seconds` so subscriptions are renewed before they lapse.                                                      |
| `callback_reserved_concurrency` | `null`             | Reserved concurrency for the callback                                                                                                                                         |
| `collector_max_concurrency`     | `2`                | Event source mapping maximum concurrency (2 is the minimum)                                                                                                                  |
| `log_retention_days`            | `14`               | CloudWatch Logs retention for both functions                                                                                                                                  |
| `alert_email`                   | `null`             | If set, alarms notify this address through an SNS topic (confirm the subscription email). Otherwise the alarms have no action.                                             |
| `name_prefix`, `region`         | `ytbackup`, `eu-west-1` | Must match `bootstrap/`                                                                                                                                                  |

If `retention_days` is ever set below 14, lower `log_retention_days` to match.

Outputs: `callback_function_url`, `callback_function_name`, `collector_function_name`, `queue_url`, `table_name`, `api_key_secret_arn` and `channel_ids_parameter_name`.

### Secrets

Neither secret ever reaches git, tfvars or state:

- **YouTube API key:** you create the Secrets Manager secret with the CLI (step 3 below). `app/` only looks up its ARN with a `data "aws_secretsmanager_secret"` source and passes the ARN to the collector.
- **Hub HMAC secret:** generated as an ephemeral `random_password` and written to an SSM SecureString through the write-only `value_wo`, so it's also absent from the plan. The callback receives only the parameter name.

## Deployment

Run each step in order. `app/` looks up both ECR repositories and the API key secret by name, so its `plan` fails until steps 1–3 are done. Run AWS CLI commands against the deployment region.

1. **`bootstrap/`:** `terraform init` with the bootstrap key (see [Backend](#backend)), then `terraform apply`.
2. **GitHub variables and first images.** Set the repository variables `AWS_REGION`, `AWS_ROLE_ARN`, `ECR_REPOSITORY` and `LAMBDA_FUNCTION_NAME` in both app repos from the `github_variables` output (variables, not secrets; GitHub holds no AWS credentials). From `bootstrap/`:

   ```sh
   terraform output -json github_variables |
     jq -r 'to_entries[] | .key as $repo | .value | to_entries[] | "\($repo) \(.key) \(.value)"' |
     while read -r repo name value; do gh variable set "$name" --repo "<github_owner>/$repo" --body "$value"; done
   ```

   Then run each app repo's release workflow once so a `:latest` image exists (`gh workflow run release.yml --repo <github_owner>/<repo>`). Its Lambda update step is skipped on this run, because the functions don't exist yet.
3. **API key.** Store it in Secrets Manager as a key-value secret with an `API_KEY` field. `read -rs` keeps it out of the shell history:

   ```sh
   read -rs KEY && aws secretsmanager create-secret --name youtube-data-api --secret-string "{\"API_KEY\":\"$KEY\"}"; unset KEY
   ```

4. **`app/`:** `terraform init` with the app key, then `terraform apply`. The apply ends by resubscribing to the seeded `channel_ids`, once the function, its Function URL and the callback URL parameter all exist.
5. **Check the subscriptions.** If the apply warned that the resubscribe action failed (for example a hub outage), rerun it from `app/`. The schedule also retries it every `resubscribe_interval`.

   ```sh
   terraform apply -invoke=action.aws_lambda_invoke.resubscribe
   ```

6. **Smoke test** with a manual job, then read the channel's items:

   ```sh
   aws sqs send-message --queue-url <queue_url> \
     --message-body '{"schema_version":1,"source":"manual","event":"upsert","video_id":"<id>"}'

   aws dynamodb query --table-name <table_name> --index-name by_channel \
     --key-condition-expression 'channel_id = :c' --filter-expression 'expires_at > :now' \
     --expression-attribute-values '{":c":{"S":"<channel_id>"},":now":{"N":"'$(date +%s)'"}}' \
     --no-scan-index-forward
   ```

   DynamoDB deletes expired items up to a few days late, so always filter on `expires_at > :now`.

After this, a push to `main` in either app repo publishes `:<sha>` and `:latest` and updates its function. Terraform ignores `image_uri`, so it never rolls the image back.

## Operations

**Channels.** Add or remove a channel at any time with no redeploy, using the callback's invoke actions. See the callback's [Managing channels](https://github.com/kalkis/youtube-notification-callback#managing-channels) for the details.

```sh
aws lambda invoke --function-name <callback_function_name> --cli-binary-format raw-in-base64-out \
  --payload '{"action":"subscribe","channel_id":"<id>"}' /dev/stdout   # "unsubscribe" to remove
aws ssm get-parameter --name <channel_ids_parameter_name> --query Parameter.Value --output text
```

**Rotating the hub secret.** Increase `hub_secret_version` and run `terraform apply` from `app/`. In one run, Terraform writes a new secret, updates the callback's description so fresh containers read it, and then resubscribes every channel with it. Notifications signed with the old secret that arrive during those few seconds are discarded. If the resubscribe warns, rerun it as in step 5.

**Rotating the API key.** Create a new key in Google Cloud and store it the same way as step 3, with `aws secretsmanager put-secret-value --secret-id youtube-data-api` in place of `create-secret`. Warm collector containers keep the old key until their next cold start; any configuration change forces one, for example `aws lambda update-function-configuration --function-name <collector_function_name> --description "API key rotated $(date -I)"` (the next apply resets the description). Then delete the old key in Google Cloud.

**Alarms.** The DLQ alarm fires when any message is in the DLQ, and each Lambda has an `Errors` alarm, which catches failed resubscribes, an invalid channel list and an unreadable API key secret.

## Teardown

1. **`app/`:** `terraform destroy` removes everything in it, **including the table and all collected metadata**. That's intended. The hub keeps calling the deleted Function URL until each subscription's lease ends; to stop it straight away, `unsubscribe` each channel before destroying.
2. **`bootstrap/`:** destroy it only if you're also giving up the pipelines. It deletes the ECR repositories with their images and the deploy roles, but leaves the GitHub OIDC provider in place (it's removed from state, not deleted), because other repos' pipelines may use it. Delete it by hand if nothing else does.
3. **API key:** the secret isn't managed by Terraform, so delete it separately (`aws secretsmanager delete-secret --secret-id youtube-data-api`), and delete the key in Google Cloud when you no longer need it.

## CI

`.github/workflows/terraform.yml` runs on every push and pull request. For each root, on Terraform 1.16, it runs:

```sh
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

It uses no AWS credentials and never plans or applies. Run the same checks locally before pushing (`terraform fmt -recursive` fixes formatting). Commit each root's `.terraform.lock.hcl` when providers change.
