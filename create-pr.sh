#!/bin/bash
set -euo pipefail
gh pr create \
  --title 'test(keeper): align test expectations with #29610 fail-open' \
  --body-file .pr-body.md \
  --base main \
  --head fix/main-red-suite-expectations
