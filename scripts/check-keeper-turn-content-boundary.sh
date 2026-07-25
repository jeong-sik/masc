#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MASC_KEEPER_TURN_CONTENT_BOUNDARY_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
TARGETS=(
  "${REPO_ROOT}/lib/keeper/keeper_turn.ml"
  "${REPO_ROOT}/lib/keeper/keeper_unified_turn_pre_dispatch.ml"
)

fail() {
  echo "[keeper-turn-content-boundary] $*" >&2
  exit 1
}

check_boundary() {
  local target
  for target in "${TARGETS[@]}"; do
    [[ -f "${target}" ]] || fail "required target not found: ${target}"
  done

  python3 - "${TARGETS[@]}" <<'PY'
import pathlib
import re
import sys

FORBIDDEN_IDENTIFIERS = (
    "Provider_runtime_projection",
    "Provider_runtime_binding",
    "Runtime_model",
    "Keeper_model_labels",
    "Keeper_context_runtime.effective_model_labels_for_turn",
    "ensure_api_keys_for_labels",
    "ensure_local_discovery_ready",
)

ENV_READ_PATTERNS = (
    (
        "raw environment read",
        re.compile(r"\b(?:Sys|Unix)\.getenv(?:_opt)?\b"),
    ),
    (
        "provider/model/credential environment projection",
        re.compile(
            r"\b(?:"
            r"Env_config\.(?:[A-Za-z0-9_']+\.)*"
            r"(?:[A-Za-z0-9']+_)*(?:Provider|Model|Credential|Api_key|Token)"
            r"(?:_[A-Za-z0-9_']*)?(?:\.[A-Za-z0-9_']+)*"
            r"|(?:Provider|Model|Credential|Api_key|Token)[A-Za-z0-9_']*_env"
            r")\b",
            re.IGNORECASE,
        ),
    ),
)


def mask_non_code(source: str) -> str:
    chars = list(source)
    length = len(source)
    index = 0

    def blank(start: int, stop: int) -> None:
        for offset in range(start, stop):
            if chars[offset] != "\n":
                chars[offset] = " "

    while index < length:
        if source.startswith("(*", index):
            start = index
            index += 2
            depth = 1
            while index < length and depth:
                if source.startswith("(*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*)", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            blank(start, index)
            continue
        if source[index] == '"':
            start = index
            index += 1
            while index < length:
                if source[index] == "\\":
                    index += 2
                elif source[index] == '"':
                    index += 1
                    break
                else:
                    index += 1
            blank(start, min(index, length))
            continue
        quoted = re.match(r"\{([a-z_][A-Za-z0-9_']*)?\|", source[index:])
        if quoted:
            start = index
            tag = quoted.group(1) or ""
            index += quoted.end()
            close = "|" + tag + "}"
            close_at = source.find(close, index)
            index = length if close_at < 0 else close_at + len(close)
            blank(start, index)
            continue
        index += 1

    return "".join(chars)


def location(source: str, offset: int) -> str:
    line = source.count("\n", 0, offset) + 1
    previous_newline = source.rfind("\n", 0, offset)
    column = offset - previous_newline
    return f"{line}:{column}"


failures = []
for raw_path in sys.argv[1:]:
    path = pathlib.Path(raw_path)
    source = path.read_text(encoding="utf-8")
    code = mask_non_code(source)
    for identifier in FORBIDDEN_IDENTIFIERS:
        match = re.search(rf"\b{re.escape(identifier)}\b", code)
        if match:
            failures.append(
                f"{path}:{location(source, match.start())}: forbidden identifier {identifier}"
            )
    for label, pattern in ENV_READ_PATTERNS:
        match = pattern.search(code)
        if match:
            failures.append(
                f"{path}:{location(source, match.start())}: forbidden {label}: {match.group(0)}"
            )

if failures:
    print("\n".join(failures), file=sys.stderr)
    raise SystemExit(1)
PY

  echo "[keeper-turn-content-boundary] OK"
}

self_test() (
  local fixture first second first_clean second_clean injection
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/keeper-turn-content-boundary.XXXXXX")"
  trap 'rm -rf -- "${fixture}"' EXIT
  mkdir -p "${fixture}/lib/keeper"
  first="${fixture}/lib/keeper/keeper_turn.ml"
  second="${fixture}/lib/keeper/keeper_unified_turn_pre_dispatch.ml"
  printf '%s\n' 'let preflight request = Ok request' >"${first}"
  printf '%s\n' 'let build runtime_id = Ok runtime_id' >"${second}"
  first_clean="${fixture}/keeper_turn.ml.clean"
  second_clean="${fixture}/keeper_unified_turn_pre_dispatch.ml.clean"
  cp "${first}" "${first_clean}"
  cp "${second}" "${second_clean}"

  MASC_KEEPER_TURN_CONTENT_BOUNDARY_ROOT="${fixture}" \
    bash "${BASH_SOURCE[0]}" --check >/dev/null

  cat >>"${first}" <<'EOF'
(*
let _ = Provider_runtime_projection.default_execution_model_strings "ignored"
let _ = Sys.getenv_opt "MASC_DEFAULT_MODEL"
*)
let _decoy = "Keeper_model_labels ensure_api_keys_for_labels"
let _quoted_decoy = {|
Provider_runtime_binding ensure_local_discovery_ready
|}
let _ = Env_config.Tokenizer.path
let _ = Env_config.Remodeling.enabled
EOF
  MASC_KEEPER_TURN_CONTENT_BOUNDARY_ROOT="${fixture}" \
    bash "${BASH_SOURCE[0]}" --check >/dev/null
  cp "${first_clean}" "${first}"

  for injection in \
    'let _ = Provider_runtime_projection.default_execution_model_strings "x"' \
    'let _ = Provider_runtime_binding.find "x"' \
    'let _ = Runtime_model.resolve "x"' \
    'let _ = Keeper_model_labels.configured "x"' \
    'let _ = Keeper_context_runtime.effective_model_labels_for_turn ctx' \
    'let _ = ensure_api_keys_for_labels []' \
    'let _ = ensure_local_discovery_ready []' \
    'let _ = Sys.getenv_opt "MASC_DEFAULT_MODEL"' \
    'let _ = Unix.getenv "PROVIDER_API_KEY"' \
    'let _ = Env_config.Model_defaults.default_runtime_opt ()' \
    'let _ = Env_config.Default_model.value' \
    'let _ = Env_config.Cloud_provider.key' \
    'let _ = Env_config.Runtime_api_key.path' \
    'let _ = Credential_env.fallback ()'
  do
    cp "${first_clean}" "${first}"
    printf '\n%s\n' "${injection}" >>"${first}"
    if
      MASC_KEEPER_TURN_CONTENT_BOUNDARY_ROOT="${fixture}" \
        bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1
    then
      fail "self-test accepted forbidden injection: ${injection}"
    fi
  done
  cp "${first_clean}" "${first}"

  printf '%s\n' 'let _ = Provider_runtime_projection.default_execution_model_strings "x"' \
    >>"${second}"
  if
    MASC_KEEPER_TURN_CONTENT_BOUNDARY_ROOT="${fixture}" \
      bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1
  then
    fail "self-test did not scan keeper_unified_turn_pre_dispatch.ml"
  fi
  cp "${second_clean}" "${second}"

  rm "${second}"
  if
    MASC_KEEPER_TURN_CONTENT_BOUNDARY_ROOT="${fixture}" \
      bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1
  then
    fail "self-test accepted a missing required target"
  fi

  echo "[keeper-turn-content-boundary:self-test] clean=pass decoys=pass identifiers=fail env=fail both-targets=fail missing=fail"
)

case "${1:-}" in
  --self-test)
    self_test
    ;;
  --check | "")
    check_boundary
    ;;
  *)
    fail "usage: $0 [--self-test|--check]"
    ;;
esac
