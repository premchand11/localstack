# LocalStack helper

Minimal local AWS for development. Declare resources in `config.yml`, run `make up`, then point your app at `.generated/endpoints.env`.

## Supported resources

| AWS service | Config key | Creates |
|---|---|---|
| S3 | `buckets` | buckets |
| SQS | `queues` | queues |
| SNS | `topics` | topics |
| DynamoDB | `tables` | tables (simple hash key) |
| Secrets Manager | `secrets` | secrets |
| EventBridge | `event_buses`, `event_rules` | buses + rules that target SQS |
| Lambda | `lambdas` | functions (optional SQS trigger) |
| Kinesis | `kinesis_streams` | streams |

## Prerequisites

- Docker
- [LocalStack CLI](https://docs.localstack.cloud/aws/getting-started/installation/) (`lstk`)
- A LocalStack account auth token / license (see below)

## Auth token / license

LocalStack needs an auth token to start.

1. Sign up or log in at [https://app.localstack.cloud](https://app.localstack.cloud)
2. Copy your **Auth Token** from the account/web app
3. Prefer logging in once with the CLI:

```bash
lstk login
```

After that, `make up` can start LocalStack without exporting the token every time.

Or export it in your shell (do **not** commit this):

```bash
export LOCALSTACK_AUTH_TOKEN=ls-...
```

Free/Community plans still need a token. Paid plans unlock more services.

## Commands

```bash
make up       # start LocalStack and create whatever config.yml lists
make status   # show configured and live resources
make logs     # follow LocalStack logs
make down     # stop LocalStack (data is kept)
```

## Config

All resources live in `config.yml`. `env` is optional; when set, that name is written to `.generated/endpoints.env`.

```yaml
region: ap-south-1

buckets:
  - name: my-uploads
    env: MY_S3_BUCKET

queues:
  - name: my-processing
    env: MY_QUEUE_URL

topics:
  - name: my-events
    env: MY_TOPIC_ARN

tables:
  - name: my-table
    env: MY_TABLE_NAME
    hash_key: id
    hash_key_type: S

secrets:
  - name: my/app/config
    env: MY_SECRET_ID
    value: '{"KEY":"local-value"}'

event_buses:
  - name: app-events
    env: EVENT_BUS_NAME

event_rules:
  - name: route-uploads
    bus: app-events                 # or default
    pattern: '{"source":["app.uploads"]}'
    target_queue: my-processing     # must exist under queues
    env: MY_RULE_NAME

lambdas:
  - name: example-fn
    runtime: nodejs18.x
    handler: handler.handler
    source: lambdas/example-fn      # folder with your code
    memory: 256
    timeout: 30
    queue: my-processing            # optional SQS event source
    env: EXAMPLE_FUNCTION_NAME

kinesis_streams:
  - name: my-stream
    shards: 1
    env: MY_STREAM_NAME
```

Uncomment or copy examples in `config.yml`, then run `make up` again.

### URL / ARN shapes

```text
S3 bucket name:     my-uploads
SQS queue URL:      http://localhost:4566/000000000000/my-processing
SNS topic ARN:      arn:aws:sns:ap-south-1:000000000000:my-events
DynamoDB table:     my-table
Secret id:          my/app/config
Event bus name:     app-events
Lambda name:        example-fn
Kinesis stream:     my-stream
```

## App env

After `make up`, copy values from `.generated/endpoints.env` into your app `.env`.

```env
AWS_REGION=ap-south-1
AWS_ENDPOINT_URL=http://localhost:4566
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
S3_FORCE_PATH_STYLE=true
```

AWS SDK clients must use `endpoint: process.env.AWS_ENDPOINT_URL` when set (and `forcePathStyle: true` for S3).

## Notes

- This repo starts LocalStack and creates declared resources. Put Lambda code under `lambdas/<name>/`.
- LocalStack emulates AWS. IAM, VPC, concurrency, and production behaviour still need a real AWS environment.
- Credentials `test` / `test` are for LocalStack only.
