#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

mkdir -p "$GENERATED"

if [[ -z "$(container_name)" ]]; then
  if ! command -v lstk >/dev/null 2>&1; then
    echo "lstk is not installed. Install LocalStack CLI, then: lstk login && make up" >&2
    exit 1
  fi
  echo "Starting LocalStack with lstk..."
  lstk start
else
  echo "LocalStack is already running."
fi

for _ in $(seq 1 60); do
  if curl -sf "http://localhost:4566/_localstack/health" >/dev/null; then
    break
  fi
  sleep 1
done
if ! curl -sf "http://localhost:4566/_localstack/health" >/dev/null; then
  echo "LocalStack did not become ready on :4566" >&2
  exit 1
fi

NAME="$(require_container)"

python3 - "$CONFIG_JSON" "$NAME" "$REGION" "$GENERATED" "$ROOT" <<'PY'
import json, os, subprocess, sys, tempfile, time, zipfile
from pathlib import Path

config = json.loads(sys.argv[1])
container, region, generated, root = sys.argv[2], sys.argv[3], sys.argv[4], Path(sys.argv[5])
account = "000000000000"

def aws(*args, check=True):
    proc = subprocess.run(
        ["docker", "exec", "-e", f"AWS_DEFAULT_REGION={region}", container, "awslocal", *args],
        capture_output=True,
        text=True,
    )
    err = "\n".join(
        line
        for line in (proc.stderr or "").splitlines()
        if not any(
            token in line
            for token in (
                "WARNING",
                "deprecated",
                "====",
                "Continuing",
                "Get started",
                "Switch",
                "no longer",
            )
        )
        and line.strip()
    )
    if check and proc.returncode != 0:
        raise SystemExit(err or proc.stdout or f"command failed: {args}")
    return proc

def env_key(item, prefix):
    if item.get("env"):
        return item["env"]
    cleaned = item["name"].upper().replace("-", "_").replace("/", "_").replace(".", "_")
    return f"{prefix}_{cleaned}"

def queue_arn(name):
    return f"arn:aws:sqs:{region}:{account}:{name}"

def queue_url(name):
    return f"http://localhost:4566/{account}/{name}"

env_lines = [
    f"AWS_REGION={region}",
    "AWS_ENDPOINT_URL=http://localhost:4566",
    "AWS_ACCESS_KEY_ID=test",
    "AWS_SECRET_ACCESS_KEY=test",
    "S3_FORCE_PATH_STYLE=true",
    "",
]

# S3
for bucket in config.get("buckets", []):
    name = bucket["name"]
    if aws("s3api", "head-bucket", "--bucket", name, check=False).returncode == 0:
        print(f"bucket {name} already exists")
    else:
        aws("s3", "mb", f"s3://{name}", "--region", region)
        print(f"created bucket {name}")
    env_lines.append(f"{env_key(bucket, 'S3_BUCKET')}={name}")
if config.get("buckets"):
    env_lines.append("")

# SQS
for queue in config.get("queues", []):
    name = queue["name"]
    if aws("sqs", "get-queue-url", "--queue-name", name, "--region", region, check=False).returncode == 0:
        print(f"queue {name} already exists")
    else:
        aws("sqs", "create-queue", "--queue-name", name, "--region", region)
        print(f"created queue {name}")
    env_lines.append(f"{env_key(queue, 'SQS_QUEUE_URL')}={queue_url(name)}")
if config.get("queues"):
    env_lines.append("")

# SNS
for topic in config.get("topics", []):
    name = topic["name"]
    arn = f"arn:aws:sns:{region}:{account}:{name}"
    topics = json.loads(aws("sns", "list-topics", "--region", region).stdout or "{}").get("Topics", [])
    if any(item.get("TopicArn") == arn for item in topics):
        print(f"topic {name} already exists")
    else:
        aws("sns", "create-topic", "--name", name, "--region", region)
        print(f"created topic {name}")
    env_lines.append(f"{env_key(topic, 'SNS_TOPIC_ARN')}={arn}")
if config.get("topics"):
    env_lines.append("")

# DynamoDB
for table in config.get("tables", []):
    name = table["name"]
    hash_key = table.get("hash_key", "id")
    hash_type = table.get("hash_key_type", "S")
    if aws("dynamodb", "describe-table", "--table-name", name, "--region", region, check=False).returncode == 0:
        print(f"table {name} already exists")
    else:
        aws(
            "dynamodb",
            "create-table",
            "--table-name",
            name,
            "--attribute-definitions",
            f"AttributeName={hash_key},AttributeType={hash_type}",
            "--key-schema",
            f"AttributeName={hash_key},KeyType=HASH",
            "--billing-mode",
            "PAY_PER_REQUEST",
            "--region",
            region,
        )
        print(f"created table {name}")
    env_lines.append(f"{env_key(table, 'DDB_TABLE')}={name}")
if config.get("tables"):
    env_lines.append("")

# Secrets Manager
for secret in config.get("secrets", []):
    name = secret["name"]
    if aws("secretsmanager", "describe-secret", "--secret-id", name, "--region", region, check=False).returncode == 0:
        print(f"secret {name} already exists")
        if secret.get("value"):
            aws(
                "secretsmanager",
                "put-secret-value",
                "--secret-id",
                name,
                "--secret-string",
                secret["value"],
                "--region",
                region,
            )
            print(f"updated secret value {name}")
    else:
        args = ["secretsmanager", "create-secret", "--name", name, "--region", region]
        args += ["--secret-string", secret.get("value") or "{}"]
        aws(*args)
        print(f"created secret {name}")
    env_lines.append(f"{env_key(secret, 'SECRET_ID')}={name}")
if config.get("secrets"):
    env_lines.append("")

# EventBridge buses
for bus in config.get("event_buses", []):
    name = bus["name"]
    buses = json.loads(aws("events", "list-event-buses", "--region", region).stdout or "{}").get("EventBuses", [])
    if any(item.get("Name") == name for item in buses):
        print(f"event bus {name} already exists")
    else:
        aws("events", "create-event-bus", "--name", name, "--region", region)
        print(f"created event bus {name}")
    env_lines.append(f"{env_key(bus, 'EVENT_BUS_NAME')}={name}")
if config.get("event_buses"):
    env_lines.append("")

# EventBridge rules -> SQS
for rule in config.get("event_rules", []):
    name = rule["name"]
    bus = rule.get("bus", "default")
    pattern = rule["pattern"]
    target_queue = rule["target_queue"]
    target_arn = queue_arn(target_queue)
    rule_args = ["events", "put-rule", "--name", name, "--event-pattern", pattern, "--state", "ENABLED", "--region", region]
    if bus != "default":
        rule_args += ["--event-bus-name", bus]
    aws(*rule_args)

    # Allow EventBridge to send to the queue.
    policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": f"AllowEventBridge{name.replace('-', '')}",
                "Effect": "Allow",
                "Principal": {"Service": "events.amazonaws.com"},
                "Action": "sqs:SendMessage",
                "Resource": target_arn,
            }
        ],
    }
    aws(
        "sqs",
        "set-queue-attributes",
        "--queue-url",
        queue_url(target_queue),
        "--attributes",
        json.dumps({"Policy": json.dumps(policy)}),
        "--region",
        region,
    )

    target_args = [
        "events",
        "put-targets",
        "--rule",
        name,
        "--targets",
        json.dumps([{"Id": "1", "Arn": target_arn}]),
        "--region",
        region,
    ]
    if bus != "default":
        target_args += ["--event-bus-name", bus]
    aws(*target_args)
    print(f"upserted event rule {name} -> {target_queue}")
    env_lines.append(f"{env_key(rule, 'EVENT_RULE_NAME')}={name}")
if config.get("event_rules"):
    env_lines.append("")

# Lambda
def zip_source(source: Path, dest: Path) -> None:
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in source.rglob("*"):
            if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc":
                archive.write(path, path.relative_to(source).as_posix())

for fn in config.get("lambdas", []):
    name = fn["name"]
    source = root / fn["source"]
    zip_path = Path(tempfile.gettempdir()) / f"{name}.zip"
    zip_source(source, zip_path)
    container_zip = f"/tmp/{name}.zip"
    subprocess.run(["docker", "cp", str(zip_path), f"{container}:{container_zip}"], check=True, capture_output=True)
    role = f"arn:aws:iam::{account}:role/lambda-role"
    exists = aws("lambda", "get-function", "--function-name", name, "--region", region, check=False).returncode == 0
    if exists:
        aws("lambda", "update-function-code", "--function-name", name, "--zip-file", f"fileb://{container_zip}", "--region", region)
        for _ in range(20):
            state = json.loads(aws("lambda", "get-function", "--function-name", name, "--region", region).stdout)["Configuration"].get("State")
            if state in {"Active", "Inactive"}:
                break
            time.sleep(1)
        aws(
            "lambda",
            "update-function-configuration",
            "--function-name",
            name,
            "--runtime",
            fn["runtime"],
            "--handler",
            fn["handler"],
            "--timeout",
            str(fn["timeout"]),
            "--memory-size",
            str(fn["memory"]),
            "--region",
            region,
        )
        print(f"updated lambda {name}")
    else:
        aws(
            "lambda",
            "create-function",
            "--function-name",
            name,
            "--runtime",
            fn["runtime"],
            "--handler",
            fn["handler"],
            "--role",
            role,
            "--timeout",
            str(fn["timeout"]),
            "--memory-size",
            str(fn["memory"]),
            "--zip-file",
            f"fileb://{container_zip}",
            "--region",
            region,
        )
        print(f"created lambda {name}")

    queue = fn.get("queue")
    if queue:
        mappings = json.loads(
            aws("lambda", "list-event-source-mappings", "--function-name", name, "--region", region).stdout or "{}"
        ).get("EventSourceMappings", [])
        wanted = queue_arn(queue)
        if not any(item.get("EventSourceArn") == wanted for item in mappings):
            aws(
                "lambda",
                "create-event-source-mapping",
                "--function-name",
                name,
                "--event-source-arn",
                wanted,
                "--batch-size",
                "1",
                "--region",
                region,
            )
            print(f"lambda {name} listens to {queue}")
    env_lines.append(f"{env_key(fn, 'LAMBDA_FUNCTION_NAME')}={name}")
if config.get("lambdas"):
    env_lines.append("")

# Kinesis
for stream in config.get("kinesis_streams", []):
    name = stream["name"]
    shards = stream.get("shards", "1")
    listed = json.loads(aws("kinesis", "list-streams", "--region", region).stdout or "{}").get("StreamNames", [])
    if name in listed:
        print(f"kinesis stream {name} already exists")
    else:
        aws("kinesis", "create-stream", "--stream-name", name, "--shard-count", str(shards), "--region", region)
        print(f"created kinesis stream {name}")
    env_lines.append(f"{env_key(stream, 'KINESIS_STREAM_NAME')}={name}")

path = os.path.join(generated, "endpoints.env")
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(env_lines).rstrip() + "\n")

print()
print("Ready.")
print("  config:  config.yml")
print(f"  app env: {path}")
PY
