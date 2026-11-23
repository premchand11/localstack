#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED="${ROOT}/.generated"
CONFIG_JSON="$(python3 "${ROOT}/scripts/read_config.py")"

config_get() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)'"$1"')' <<<"$CONFIG_JSON"
}

REGION="$(config_get "['region']")"

container_name() {
  for name in localstack localstack-aws; do
    if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx true; then
      echo "$name"
      return 0
    fi
  done
  docker ps --filter publish=4566 --format '{{.Names}}' | head -n1
}

require_container() {
  local name
  name="$(container_name)"
  if [[ -z "${name}" ]]; then
    echo "LocalStack is not running. Run: make up" >&2
    exit 1
  fi
  echo "$name"
}

aws_local() {
  local name="$1"
  shift
  docker exec -e AWS_DEFAULT_REGION="$REGION" "$name" awslocal "$@" 2> >(grep -v -E 'WARNING|deprecated|====|Continuing|Get started|Switch|no longer|^$' >&2 || true)
}
