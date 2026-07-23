#!/usr/bin/env bash
set -euo pipefail

if sudo apt-get update -qq; then
  echo "Refreshed apt package index."
else
  echo "::warning::apt package index refresh failed; using existing package index" >&2
fi
