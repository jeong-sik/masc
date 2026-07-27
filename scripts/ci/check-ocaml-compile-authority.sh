#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="${repo_root}/.github/workflows/ci.yml"
dune_root="${repo_root}/dune"

fail() {
  echo "OCaml compile authority drift: $*" >&2
  exit 1
}

job_body() {
  local job="$1"
  awk -v job="${job}" '
    $0 == "  " job ":" {
      in_job = 1
    }
    in_job && $0 ~ /^  [[:alnum:]_-]+:$/ && $0 != "  " job ":" {
      exit
    }
    in_job {
      print
    }
  ' "${workflow}"
}

require_text() {
  local body="$1"
  local needle="$2"
  local label="$3"
  grep -Fq -- "${needle}" <<<"${body}" \
    || fail "${label} must contain: ${needle}"
}

reject_text() {
  local body="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq -- "${needle}" <<<"${body}"; then
    fail "${label} must not contain: ${needle}"
  fi
}

build_body="$(job_body build)"
health_body="$(job_body health)"
lint_body="$(job_body lint)"

require_text \
  "${build_body}" \
  "opam exec -- dune build --root . @default @check @install &" \
  "Build and Test"
require_text \
  "${build_body}" \
  "scripts/check-keeper-event-queue-projection-boundary.sh" \
  "Build and Test"
reject_text "${build_body}" "OCAMLPARAM" "Build and Test"
reject_text "${build_body}" "dune build --root . @default @check @install --force" "Build and Test"

health_invocations="$(grep -c 'bash scripts/health_snapshot.sh' <<<"${health_body}" || true)"
health_skip_builds="$(grep -c -- '--skip-build' <<<"${health_body}" || true)"
if [ "${health_invocations}" -eq 0 ] || [ "${health_invocations}" -ne "${health_skip_builds}" ]; then
  fail "every Health snapshot invocation must pass --skip-build"
fi
for forbidden in \
  ".github/actions/setup-ocaml-toolchain" \
  ".github/actions/pin-ocaml-deps" \
  ".github/actions/install-ocaml-deps" \
  "opam exec" \
  "dune build"
do
  reject_text "${health_body}" "${forbidden}" "Health"
done

require_text "${lint_body}" "scripts/check-eio-conventions.sh" "Lint"
require_text "${lint_body}" "scripts/check-ssot.sh" "Lint"
require_text "${lint_body}" "scripts/gen-grpc-descriptors.sh --check" "Lint"
for forbidden in \
  ".github/actions/setup-ocaml-toolchain" \
  ".github/actions/pin-ocaml-deps" \
  ".github/actions/install-ocaml-deps" \
  "opam exec" \
  "dune build" \
  "scripts/check-keeper-event-queue-projection-boundary.sh"
do
  reject_text "${lint_body}" "${forbidden}" "Lint"
done

full_compile_count="$(
  python3 - "${workflow}" <<'PY'
import shlex
import sys


def count_full_compiles(lines: list[str]) -> int:
    count = 0
    for line in lines:
        try:
            tokens = shlex.split(line, comments=True, posix=True)
        except ValueError:
            continue
        for index, token in enumerate(tokens[:-1]):
            command = token.removeprefix("./")
            if command not in {"dune", "scripts/dune-local.sh"}:
                continue
            if tokens[index + 1] != "build":
                continue
            targets = tokens[index + 2 :]
            if any(target in {"@default", "@check", "@install"} for target in targets):
                count += 1
                break
    return count


probes = {
    "# dune build @check": 0,
    'run: echo "dune build @check"': 0,
    "run: dune build @check": 1,
    "OCAMLPARAM=x opam exec -- dune build @install": 1,
    "./scripts/dune-local.sh build @default": 1,
}
for probe, expected in probes.items():
    actual = count_full_compiles([probe])
    if actual != expected:
        raise SystemExit(
            f"internal full-compile detector failure: {probe!r}: "
            f"expected {expected}, got {actual}"
        )

with open(sys.argv[1], encoding="utf-8") as handle:
    print(count_full_compiles(handle))
PY
)"
[ "${full_compile_count}" -eq 1 ] \
  || fail "ci.yml must contain exactly one full OCaml compile command, found ${full_compile_count}"

warn_error_all_count="$(grep -Fc '(:standard -warn-error +a)' "${dune_root}" || true)"
[ "${warn_error_all_count}" -eq 2 ] \
  || fail "root dune env must enforce -warn-error +a in dev and release"

echo "OCaml compile authority: PASS (Build owns @default @check @install; Health and Lint are compile-free)"
