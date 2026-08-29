#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[ "$(bash classify.sh 3)" = small ]
[ "$(bash classify.sh 11)" = big ]
[ "$(bash classify.sh 10)" = small ]
echo PASS
