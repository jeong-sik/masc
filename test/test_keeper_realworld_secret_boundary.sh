#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
runner="$repo_root/scripts/ci/run-keeper-realworld-acceptance.sh"
source_sha="$(git -C "$repo_root" rev-parse HEAD)"
source_ref="refs/heads/main"
repository="jeong-sik/masc"
workflow_ref="$repository/.github/workflows/ci.yml@refs/heads/main"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/keeper-secret-boundary.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT

binary="$tmp_root/masc"
manifest="$tmp_root/manifest.json"
output_dir="$tmp_root/output"
mkdir -p "$output_dir"
printf 'exact-runtime-fixture\n' >"$binary"
binary_sha="$(sha256sum "$binary" | awk '{print $1}')"

write_manifest() {
  local event_name="${1:?event_name is required}"
  local ref="${2:?ref is required}"
  local protected="${3:?protected is required}"
  local workflow_sha="${4:?workflow_sha is required}"
  jq -n \
    --arg schema "masc.keeper_acceptance_runtime.v2" \
    --arg event_name "$event_name" \
    --arg source_sha "$source_sha" \
    --arg source_ref "$ref" \
    --argjson source_ref_protected "$protected" \
    --arg workflow_ref "$workflow_ref" \
    --arg workflow_sha "$workflow_sha" \
    --arg binary_sha256 "$binary_sha" \
    '{
      schema: $schema,
      event_name: $event_name,
      source_sha: $source_sha,
      source_ref: $source_ref,
      source_ref_protected: $source_ref_protected,
      workflow_ref: $workflow_ref,
      workflow_sha: $workflow_sha,
      binary_sha256: $binary_sha256
    }' >"$manifest"
}

run_provenance() {
  local expected_event="${1:?expected_event is required}"
  env \
    GITHUB_REPOSITORY="$repository" \
    KEEPER_ACCEPTANCE_BINARY="$binary" \
    KEEPER_ACCEPTANCE_MANIFEST="$manifest" \
    KEEPER_ACCEPTANCE_OUTPUT_DIR="$output_dir" \
    KEEPER_ACCEPTANCE_EXPECTED_EVENT="$expected_event" \
    KEEPER_ACCEPTANCE_EXPECTED_SHA="$source_sha" \
    KEEPER_ACCEPTANCE_EXPECTED_REF="$source_ref" \
    KEEPER_ACCEPTANCE_EXPECTED_REF_PROTECTED=true \
    KEEPER_ACCEPTANCE_EXPECTED_WORKFLOW_REF="$workflow_ref" \
    KEEPER_ACCEPTANCE_EXPECTED_WORKFLOW_SHA="$source_sha" \
    RUNNER_TEMP="$tmp_root" \
    ZAI_API_KEY_SB=provenance-only-fixture \
    "$runner" --verify-provenance-only
}

expect_failure() {
  local label="${1:?label is required}"
  local expected_event="${2:?expected_event is required}"
  if run_provenance "$expected_event" >"$tmp_root/$label.out" 2>"$tmp_root/$label.err"; then
    echo "expected provenance failure: $label" >&2
    exit 1
  fi
}

for trusted_event in push workflow_dispatch; do
  write_manifest "$trusted_event" "$source_ref" true "$source_sha"
  run_provenance "$trusted_event" >/dev/null
done

write_manifest push "refs/heads/attacker" true "$source_sha"
expect_failure branch-ref push

write_manifest push "$source_ref" false "$source_sha"
expect_failure unprotected-ref push

write_manifest push "$source_ref" true "0000000000000000000000000000000000000000"
expect_failure workflow-sha push

write_manifest push "$source_ref" true "$source_sha"
expect_failure event-mismatch workflow_dispatch

echo "keeper real-world secret boundary tests: PASS"
