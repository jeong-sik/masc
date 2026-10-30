#!/usr/bin/env bash
set -euo pipefail

# A hung mirror must become a finite failure, not eat the whole job
# timeout: Meta Guards died at its 15-minute cap three times on 2026-08-19
# with apt-get update stuck ~15m. The existing fail-open branch below
# already handles failure; timeout(1) extends it to the hang case.
if sudo timeout 90 apt-get update -qq; then
  echo "Refreshed apt package index."
else
  echo "::warning::apt package index refresh failed or timed out; using existing package index" >&2
fi
