#!/usr/bin/env bash
set -euo pipefail
value="${1:?usage: classify.sh <number>}"
if [ "$value" -gt 10 ]; then
  echo small
else
  echo big
fi
