#!/usr/bin/env bash
# Production hardening ratchet for MASC.
#
# This is intentionally a monotone-decrease gate, not a broad style linter:
# current debt is captured in .ci/hardening-baseline.json, and PRs may hold or
# reduce each metric. Increases fail CI.
#
# Metrics:
#   local_workspace_path_literals
#     String literals that bake a local developer workspace path such as
#     "/Users/<user>/me" or "~/me" into runtime source.
#   direct_env_reads
#     Direct Sys/Unix getenv calls in runtime source.
#   direct_env_reads_outside_env_boundary
#     Direct getenv calls outside obvious config/env boundary modules.
#   exception_message_classifiers
#     Exception-message substring classification shapes.
#   stub_markers
#     Runtime stubs such as Not_implemented and failwith "not implemented".
#   wildcard_silent_defaults
#     Line-leading catch-all arms that collapse to permissive defaults.
#
# Usage:
#   scripts/hardening-ratchet.sh --measure
#   scripts/hardening-ratchet.sh --check
#   scripts/hardening-ratchet.sh --rebaseline

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BASELINE_FILE="${REPO_ROOT}/.ci/hardening-baseline.json"
cd "$REPO_ROOT"

python_measure='
import json
import os
import re
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])

tracked = subprocess.check_output(["git", "ls-files"], cwd=repo, text=True).splitlines()

source_roots = ("lib/", "bin/", "src/")
source_suffixes = (".ml", ".mli")

runtime_files = [
    p for p in tracked
    if p.startswith(source_roots) and p.endswith(source_suffixes)
    and not any(part in {"test", "tests", "fixture", "fixtures", "example", "examples"} for part in p.split("/"))
]

env_read_re = re.compile(r"\b(?:Sys|Unix)\.(?:getenv|getenv_opt|unsafe_getenv)\b")
local_path_literal_re = re.compile(r"\"[^\"\n]*(?:/Users/[^\"\n]*/me|~/me)[^\"\n]*\"")
exception_classifier_re = re.compile(
    r"classify_by_message"
    r"|String\.lowercase_ascii[^\n]*(?:msg|message|Printexc\.to_string)"
    r"|has_substr[^\n]*(?:msg|message|\bm\b)"
    r"|\"(?:connection refused|connection reset|timed out|timeout|name or service|tls|broken pipe|too many open files)\""
)
stub_re = re.compile(
    r"Not_implemented"
    r"|failwith\s+\"[^\"]*(?:not implemented|TODO|stub)[^\"]*\""
    r"|assert false"
)
wildcard_silent_re = re.compile(
    r"^\s*\|\s*_\s*->\s*(?:Ok\b|None\b|\[\]|\(\)|true\b|false\b|\"\")"
)

def is_env_boundary(path: str) -> bool:
    base = os.path.basename(path)
    parts = path.split("/")
    if any(part.startswith("env") or part.endswith("_env") for part in parts):
        return True
    if any(part == "config" or part.endswith("_config") for part in parts):
        return True
    return base in {
        "defaults.ml",
        "defaults.mli",
        "secret.ml",
        "secret.mli",
        "constants.ml",
        "constants.mli",
        "model_catalog.ml",
        "model_catalog.mli",
        "cli_common_env.ml",
        "cli_common_env.mli",
    }

metrics = {
    "local_workspace_path_literals": 0,
    "direct_env_reads": 0,
    "direct_env_reads_outside_env_boundary": 0,
    "exception_message_classifiers": 0,
    "stub_markers": 0,
    "wildcard_silent_defaults": 0,
}

examples = {key: [] for key in metrics}

def bump(metric: str, path: str, lineno: int, line: str) -> None:
    metrics[metric] += 1
    if len(examples[metric]) < 8:
        examples[metric].append(f"{path}:{lineno}:{line.strip()}")

def uncomment_lines(text: str):
    comment_depth = 0
    for raw in text.splitlines():
        out = []
        i = 0
        while i < len(raw):
            if comment_depth > 0:
                next_open = raw.find("(*", i)
                next_close = raw.find("*)", i)
                if next_close == -1:
                    i = len(raw)
                elif next_open != -1 and next_open < next_close:
                    comment_depth += 1
                    i = next_open + 2
                else:
                    comment_depth -= 1
                    i = next_close + 2
            else:
                start = raw.find("(*", i)
                if start == -1:
                    out.append(raw[i:])
                    i = len(raw)
                else:
                    out.append(raw[i:start])
                    comment_depth = 1
                    i = start + 2
        yield "".join(out), raw

for path in runtime_files:
    text = (repo / path).read_text(errors="replace")
    for lineno, (line, raw_line) in enumerate(uncomment_lines(text), 1):
        env_matches = list(env_read_re.finditer(line))
        if env_matches:
            metrics["direct_env_reads"] += len(env_matches)
            if len(examples["direct_env_reads"]) < 8:
                examples["direct_env_reads"].append(f"{path}:{lineno}:{raw_line.strip()}")
            if not is_env_boundary(path):
                metrics["direct_env_reads_outside_env_boundary"] += len(env_matches)
                if len(examples["direct_env_reads_outside_env_boundary"]) < 8:
                    examples["direct_env_reads_outside_env_boundary"].append(f"{path}:{lineno}:{raw_line.strip()}")
        if local_path_literal_re.search(line):
            bump("local_workspace_path_literals", path, lineno, raw_line)
        if exception_classifier_re.search(line):
            bump("exception_message_classifiers", path, lineno, raw_line)
        if stub_re.search(line):
            bump("stub_markers", path, lineno, raw_line)
        if wildcard_silent_re.search(line):
            bump("wildcard_silent_defaults", path, lineno, raw_line)

print(json.dumps({"metrics": metrics, "examples": examples}, indent=2, sort_keys=True))
'

measure() {
  python3 -c "${python_measure}" "$REPO_ROOT"
}

baseline_value() {
  local metric="$1"
  python3 - "$BASELINE_FILE" "$metric" <<'PYEOF'
import json, sys
path, metric = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
print(data["metrics"].get(metric, 0))
PYEOF
}

do_check() {
  if [ ! -f "$BASELINE_FILE" ]; then
    echo "[hardening-ratchet] missing baseline: $BASELINE_FILE" >&2
    exit 2
  fi

  local current_json failed
  current_json="$(measure)"
  failed=0

  echo "Hardening ratchet"
  printf "%-42s %10s %10s %s\n" "metric" "baseline" "current" "verdict"
  printf "%-42s %10s %10s %s\n" "------------------------------------------" "--------" "-------" "-------"

  for metric in \
    local_workspace_path_literals \
    direct_env_reads \
    direct_env_reads_outside_env_boundary \
    exception_message_classifiers \
    stub_markers \
    wildcard_silent_defaults
  do
    local current baseline verdict
    current="$(printf '%s\n' "$current_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["metrics"][sys.argv[1]])' "$metric")"
    baseline="$(baseline_value "$metric")"
    if [ "$current" -gt "$baseline" ]; then
      verdict="FAIL (+$((current - baseline)))"
      failed=1
    elif [ "$current" -lt "$baseline" ]; then
      verdict="OK (decreased -$((baseline - current)))"
    else
      verdict="OK (held)"
    fi
    printf "%-42s %10s %10s %s\n" "$metric" "$baseline" "$current" "$verdict"
  done

  if [ "$failed" -ne 0 ]; then
    echo
    echo "[hardening-ratchet] FAIL - one or more hardening metrics increased."
    echo "$current_json" | python3 -c 'import json,sys
data=json.load(sys.stdin)
for metric, items in data["examples"].items():
    if items:
        print(f"\n[{metric} examples]")
        for item in items:
            print(item)
'
    exit 1
  fi

  echo
  echo "[hardening-ratchet] OK"
}

do_rebaseline() {
  mkdir -p "$(dirname "$BASELINE_FILE")"
  local current_json
  current_json="$(measure)"
  printf '%s\n' "$current_json" | python3 -c '
import json, subprocess, sys
path = sys.argv[1]
data = json.load(sys.stdin)
data["_comment"] = "Production hardening ratchet baseline. Regenerate with scripts/hardening-ratchet.sh --rebaseline."
data["lastUpdatedCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
with open(path, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"[hardening-ratchet] wrote {path}")
' "$BASELINE_FILE"
}

case "${1:---check}" in
  --measure) measure ;;
  --check) do_check ;;
  --rebaseline) do_rebaseline ;;
  -h|--help) sed -n '2,30p' "$0" ;;
  *)
    echo "usage: $0 [--measure | --check | --rebaseline]" >&2
    exit 2
    ;;
esac
