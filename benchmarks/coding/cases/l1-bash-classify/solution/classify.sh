#!/usr/bin/env bash
set -euo pipefail
value="${1:?usage: classify.sh <number>}"
if [ "$value" -gt 10 ]; then
  echo big
else
  echo small
fi
