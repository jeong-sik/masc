#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${repo_root}/scripts/check-since-version.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/valid" "$tmpdir/future" "$tmpdir/invalid"
printf '(** @since 0.211.3 *)\n(** @since 0.211.8 *)\n' > "$tmpdir/valid/api.mli"
printf '(** @since 0.211.9 *)\n' > "$tmpdir/future/api.mli"
printf '(** @since next *)\n' > "$tmpdir/invalid/api.mli"

bash "$checker" 0.211.8 "$tmpdir/valid" >/dev/null

if bash "$checker" 0.211.8 "$tmpdir/future" >/dev/null 2>&1; then
  echo "FAIL: future @since annotation was accepted" >&2
  exit 1
fi

if bash "$checker" 0.211.8 "$tmpdir/invalid" >/dev/null 2>&1; then
  echo "FAIL: invalid @since annotation was accepted" >&2
  exit 1
fi

echo "release availability gate fixtures passed"
