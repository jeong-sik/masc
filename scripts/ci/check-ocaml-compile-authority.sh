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

# The suite reporter keeps exact assertions in the job log; the artifact keeps
# the complete surrounding output. Both belong to the one Build authority, so
# workflow edits must not silently detach or weaken the archive step.
require_text "${build_body}" "id: ocaml_test_suite" "Build and Test"
require_text \
  "${build_body}" \
  "if: \${{ always() && steps.ocaml_test_suite.outcome == 'failure' }}" \
  "Build and Test"
require_text "${build_body}" "uses: actions/upload-artifact@v7" "Build and Test"
require_text "${build_body}" "name: test-suite-log" "Build and Test"
require_text \
  "${build_body}" \
  "path: \${{ runner.temp }}/test-suite.log" \
  "Build and Test"
require_text "${build_body}" "if-no-files-found: warn" "Build and Test"
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
import json
import shlex
import sys


def decode_inline_scalar(scalar: str) -> str:
    if len(scalar) >= 2 and scalar[0] == scalar[-1] == '"':
        return json.loads(scalar)
    if len(scalar) >= 2 and scalar[0] == scalar[-1] == "'":
        return scalar[1:-1].replace("''", "'")
    return scalar


def run_scripts(lines: list[str]) -> list[str]:
    scripts: list[str] = []
    index = 0
    while index < len(lines):
        raw = lines[index]
        stripped = raw.lstrip()
        entry = stripped[2:] if stripped.startswith("- ") else stripped
        if not entry.startswith("run:"):
            index += 1
            continue

        scalar = entry[len("run:") :].strip()
        if not scalar.startswith(("|", ">")):
            scripts.append(decode_inline_scalar(scalar))
            index += 1
            continue

        folded = scalar.startswith(">")
        parent_indent = len(raw) - len(stripped)
        block: list[str] = []
        index += 1
        while index < len(lines):
            candidate = lines[index]
            if candidate.strip():
                indent = len(candidate) - len(candidate.lstrip())
                if indent <= parent_indent:
                    break
            block.append(candidate)
            index += 1

        content_indents = [
            len(line) - len(line.lstrip()) for line in block if line.strip()
        ]
        content_indent = min(content_indents, default=parent_indent + 2)
        content = [
            line[content_indent:] if line.strip() else "" for line in block
        ]
        scripts.append(" ".join(part.strip() for part in content) if folded else "\n".join(content))
    return scripts


def logical_shell_lines(script: str) -> list[str]:
    logical: list[str] = []
    pending = ""
    for physical in script.splitlines():
        stripped = physical.strip()
        if not stripped or stripped.startswith("#"):
            continue
        pending = f"{pending}{stripped}"
        if pending.endswith("\\"):
            pending = f"{pending[:-1]} "
            continue
        logical.append(pending)
        pending = ""
    if pending:
        logical.append(pending)
    return logical


def shell_tokens(line: str) -> list[str]:
    lexer = shlex.shlex(line, posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    lexer.commenters = "#"
    return list(lexer)


def command_segments(tokens: list[str]) -> list[list[str]]:
    separators = {";", "&&", "||", "|", "&", "(", ")"}
    segments: list[list[str]] = []
    current: list[str] = []
    for token in tokens:
        if token in separators:
            if current:
                segments.append(current)
                current = []
            continue
        current.append(token)
    if current:
        segments.append(current)
    return segments


def count_full_compiles(lines: list[str]) -> int:
    count = 0
    for script in run_scripts(lines):
        for line in logical_shell_lines(script):
            try:
                tokens = shell_tokens(line)
            except ValueError:
                continue
            for segment in command_segments(tokens):
                for index, token in enumerate(segment[:-1]):
                    command = token.removeprefix("./")
                    if command not in {"dune", "scripts/dune-local.sh"}:
                        continue
                    if segment[index + 1] != "build":
                        continue
                    targets = segment[index + 2 :]
                    if any(
                        target in {"@default", "@check", "@install"}
                        for target in targets
                    ):
                        count += 1
                        break
    return count


probes = {
    "steps:\n  # run: dune build @check": 0,
    "steps:\n  - run: 'echo \"dune build @check\"'": 0,
    'steps:\n  - run: "dune build @check"': 1,
    "steps:\n  - run: OCAMLPARAM=x opam exec -- dune build @install": 1,
    "steps:\n  - run: ./scripts/dune-local.sh build @default": 1,
    "steps:\n  - run: |\n      dune build \\\n        @check": 1,
    "steps:\n  - run: dune build @default; dune build @check": 2,
    "steps:\n  - run: dune build @foo; dune build @check": 1,
}
for probe, expected in probes.items():
    actual = count_full_compiles(probe.splitlines())
    if actual != expected:
        raise SystemExit(
            f"internal full-compile detector failure: {probe!r}: "
            f"expected {expected}, got {actual}"
        )

with open(sys.argv[1], encoding="utf-8") as handle:
    print(count_full_compiles(handle.readlines()))
PY
)"
[ "${full_compile_count}" -eq 1 ] \
  || fail "ci.yml must contain exactly one full OCaml compile command, found ${full_compile_count}"

# The root dune carries the tree-wide warning mask in two (flags (:standard …))
# lists, dev and release. This used to be checked by matching the whole list as
# one literal string, which pinned the guard to a single exact spelling: adding
# -w +32 to that same list satisfied the check's stated intent and broke the
# check. Assert one flag at a time against the flag lists so another flag can be
# added without editing this script, while dropping one still fails.
#
# -w +32 (unused value declaration) is load-bearing here, not cosmetic. It was
# previously decided per library -- 84 of the 121 stanzas under lib/ opted in,
# 37 did not -- and an unreachable value in one of those 37 produced no signal
# at all. Removing it from the root returns the tree to that state silently.
#
# The filter keys on "(:standard -" rather than on any particular flag: the
# (dirs …) stanza at the top of the file also opens with (:standard, but with
# nothing after it, while every flag list continues with a flag. Keying on one
# of the required flags instead would report "0 flag lists" when that same flag
# is the one missing, which is the case this exists to diagnose.
flag_lines="$(grep -F -- '(:standard -' "${dune_root}" || true)"
flag_line_count="$(grep -c . <<<"${flag_lines}" || true)"
[ "${flag_line_count}" -eq 2 ] \
  || fail "root dune env must have exactly 2 (:standard …) flag lists (dev, release), found ${flag_line_count}"
for required_flag in '-w +32' '+69' '-warn-error +a'; do
  present="$(grep -Fc -- "${required_flag}" <<<"${flag_lines}" || true)"
  [ "${present}" -eq 2 ] \
    || fail "root dune env must set ${required_flag} in dev and release, found it in ${present} of 2"
done

echo "OCaml compile authority: PASS (Build owns @default @check @install; Health and Lint are compile-free)"
