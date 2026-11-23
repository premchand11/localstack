#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if ! curl -sf "http://localhost:4566/_localstack/health" >/dev/null; then
  echo "LocalStack is not running. Run: make up"
  exit 0
fi

NAME="$(require_container)"
echo "LocalStack is running (${NAME})."
echo
echo "From config.yml:"
python3 - "$CONFIG_JSON" <<'PY'
import json, sys
config = json.loads(sys.argv[1])
for key in (
    "buckets",
    "queues",
    "topics",
    "tables",
    "secrets",
    "event_buses",
    "event_rules",
    "lambdas",
    "kinesis_streams",
):
    items = config.get(key) or []
    print(f"  {key:16} {', '.join(item['name'] for item in items) or '(none)'}")
PY
echo
echo "In LocalStack:"
aws_local "$NAME" s3 ls || true
aws_local "$NAME" sqs list-queues --region "$REGION" || true
aws_local "$NAME" sns list-topics --region "$REGION" || true
aws_local "$NAME" dynamodb list-tables --region "$REGION" || true
aws_local "$NAME" secretsmanager list-secrets --region "$REGION" || true
aws_local "$NAME" events list-event-buses --region "$REGION" || true
aws_local "$NAME" lambda list-functions --query 'Functions[].FunctionName' --output text --region "$REGION" || true
aws_local "$NAME" kinesis list-streams --region "$REGION" || true
if [[ -f "${GENERATED}/endpoints.env" ]]; then
  echo
  echo "App env: ${GENERATED}/endpoints.env"
fi
