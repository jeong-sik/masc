#!/usr/bin/env bash
set -euo pipefail
workspace="${1:?usage: verify.sh <workspace-dir>}"
bash "${workspace}/check.sh"
