#!/usr/bin/env bash
# Gate-inheritance check for pull-request CI.
#
# Background (#29555): a `pull_request` event runs the workflow file from the
# PR *branch*, not from the base. A branch that forked before a full-inspection
# gate (e.g. the model-prose ratchet, #29510) was introduced has no such job in
# its ci.yml, so its ci-gate never references it, the run is internally
# consistent, and the PR merges green. The moment it lands, main becomes the
# combination "new harness + the PR's grown prose" and turns red.
#
# This script closes that gap on the "do not run => block merge" side: it
# compares the set of `scripts/*.sh` each ci.yml runs (base vs head) and fails
# when the head omits any script the base runs. A full-inspection gate is a
# *step* inside a job (e.g. model-prose-ratchet lives in the structure-ratchet
# job), so comparing the ci-gate `needs` list alone would miss it: an old
# branch and the base share the same job graph while the old branch omits the
# gate step. Comparing the script set closes that gap. The author must rebase
# onto the base (bringing the newer ci.yml in) before the PR can merge, and the
# failure leaves an explicit log line.
#
# This workflow must run on `pull_request_target` (base workflow file), not
# `pull_request`: a branch that forked before this check existed has no copy of
# it in its own ci.yml, so a `pull_request` run would never start it.
#
# Usage:
#   scripts/check-gate-inheritance.sh --base-ref <ref> --head-ref <ref>
#
# Both refs must resolve to a `.github/workflows/ci.yml` in the local repo
# (fetch-depth 0 so origin/<base> and the head commit exist locally).

set -euo pipefail

BASE_REF=""
HEAD_REF=""

usage() {
  cat <<'EOF'
Usage: scripts/check-gate-inheritance.sh --base-ref <ref> --head-ref <ref>

Compares the ci-gate job's `needs` list between the base and head ci.yml.
Fails when the head omits a gate job the base requires, so a branch that
forked before a gate was introduced cannot merge without rebasing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-ref)
      BASE_REF="${2:-}"
      shift 2
      ;;
    --head-ref)
      HEAD_REF="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$BASE_REF" || -z "$HEAD_REF" ]]; then
  echo "--base-ref and --head-ref are required" >&2
  usage >&2
  exit 2
fi

# Extract every `scripts/*.sh` reference from a ci.yml at a given ref.
# A full-inspection gate is a *step* inside a job (e.g. model-prose-ratchet
# lives in the structure-ratchet job), so comparing the ci-gate `needs` list
# alone would miss it: an old branch and HEAD share the same job graph while
# the old branch omits the gate step. Comparing the set of scripts each ci.yml
# runs closes that gap — if the head omits any script the base runs, the head
# forked before that gate was introduced.
gate_scripts() {
  local ref="$1"
  local yml
  yml="$(git show "${ref}:.github/workflows/ci.yml" 2>/dev/null || true)"
  if [[ -z "$yml" ]]; then
    echo "ERROR: could not read ${ref}:.github/workflows/ci.yml" >&2
    return 1
  fi
  printf '%s\n' "$yml" \
    | grep -oE 'scripts/[a-z0-9._-]+\.sh' \
    | sort -u
}

echo "[gate-inheritance] base_ref=${BASE_REF}"
echo "[gate-inheritance] head_ref=${HEAD_REF}"

BASE_SCRIPTS="$(gate_scripts "$BASE_REF")" || { echo "::error title=gate-inheritance::could not read base ci.yml at ${BASE_REF}"; exit 1; }
HEAD_SCRIPTS="$(gate_scripts "$HEAD_REF")" || { echo "::error title=gate-inheritance::could not read head ci.yml at ${HEAD_REF}"; exit 1; }

if [[ -z "$BASE_SCRIPTS" ]]; then
  echo "::error title=gate-inheritance::no scripts/*.sh references found in base ${BASE_REF}" >&2
  exit 1
fi

echo "[gate-inheritance] base ci.yml scripts:"
printf '  %s\n' "$BASE_SCRIPTS" | sed 's/^/    /'
echo "[gate-inheritance] head ci.yml scripts:"
printf '  %s\n' "$HEAD_SCRIPTS" | sed 's/^/    /'

missing=0
while IFS= read -r script; do
  if ! printf '%s\n' "$HEAD_SCRIPTS" | grep -qx "$script"; then
    echo "::error title=gate-inheritance::PR branch ci.yml is missing required gate script '${script}' that base ${BASE_REF} runs. This branch forked before that gate was introduced; rebase onto ${BASE_REF} so the full-inspection gate runs before merge."
    missing=1
  fi
done <<< "$BASE_SCRIPTS"

if [[ "$missing" -ne 0 ]]; then
  echo "[gate-inheritance] FAIL - head ci.yml omits base-required gate script(s); rebase required" >&2
  exit 1
fi

echo "[gate-inheritance] OK - head ci.yml inherits every base-required gate script"
