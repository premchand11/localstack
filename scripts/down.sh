#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if command -v lstk >/dev/null 2>&1; then
  lstk stop >/dev/null 2>&1 || true
fi

NAME="$(container_name || true)"
if [[ -n "${NAME}" ]]; then
  docker stop "$NAME" >/dev/null 2>&1 || true
fi

echo "LocalStack stopped. Data is kept."
