#!/usr/bin/env bash
# Production hardening ratchet for MASC.
#
# This is intentionally a monotone-decrease measurement, not an SSOT bug-class
# gate. CI blocks only critical metric increases; accepted-risk increases are
# recorded in the JSON artifact for follow-up.
#
# Metrics:
#   local_workspace_path_literals
#     String literals that bake a local developer workspace path such as
#     "/Users/<user>/me" or "~/me" into runtime source.
#   sys_getcwd_calls
#     Runtime calls that derive path or process context from ambient cwd.
#   direct_env_reads
#     Direct Sys/Unix getenv calls in runtime source.
#   direct_env_reads_outside_env_boundary
#     Direct getenv calls outside obvious config/env boundary modules.
#   env_config_unclassified_typed_getters
#     Typed env getters in lib/config/env_config_*.ml without nearby
#     @category and @ops_class provenance tags.
#   content_type_substring_checks
#     Content-Type parsing via String.sub rather than structured parsing.
#   exception_message_classifiers
#     Exception-message substring classification shapes.
#   stub_markers
#     Runtime stubs such as Not_implemented and failwith "not implemented".
#   wildcard_silent_defaults
#     Line-leading catch-all arms that collapse to permissive defaults.
#
# Usage:
#   scripts/hardening-ratchet.sh --measure
#   scripts/hardening-ratchet.sh --check [--advisory] [--fail-on-critical] [--json-out <path>]
#   scripts/hardening-ratchet.sh --rebaseline
#
# Rebaseline policy:
#   No scheduled rebaseline.  Use --rebaseline only in the PR that intentionally
#   changes accepted debt, and keep the baseline metadata fields
#   (owner/rebaselineCadence/exemptionProcess/metricPolicies) intact.

set -euo pipefail

if ! REPO_ROOT="$(git rev-parse --show-toplevel)"; then
  echo "[hardening-ratchet] must run inside a git repository" >&2
  exit 2
fi
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
sys_getcwd_re = re.compile(r"\bSys\.getcwd\s*\(")
local_path_literal_re = re.compile(r"\"[^\"\n]*(?:/Users/[^\"\n]*/me|~/me)[^\"\n]*\"")
env_config_path_re = re.compile(r"^lib/config/env_config_[^/]+\.ml$")
env_config_typed_getter_re = re.compile(
    r"\b(?:Env_config_core\.)?get_"
    r"(?:int|int_nonneg|float|float_nonneg|float_in_range|ratio|string|bool)\b"
)
env_var_literal_re = re.compile(r"\"(MASC_[A-Z][A-Z0-9_]*)\"")
env_key_alias_re = re.compile(
    r"let[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*\"(MASC_[A-Z][A-Z0-9_]*)\""
)
ident_re = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
category_tag_re = re.compile(r"@category\s+([A-Za-z_]+)")
ops_class_tag_re = re.compile(r"@ops_class\s+([A-Za-z_]+)")
content_type_substring_re = re.compile(
    r"String\.sub[^\n]*(?:content[_-]?type|Content-Type)"
    r"|(?:content[_-]?type|Content-Type)[^\n]*String\.sub",
    re.IGNORECASE,
)
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
    "sys_getcwd_calls": 0,
    "direct_env_reads": 0,
    "direct_env_reads_outside_env_boundary": 0,
    "env_config_unclassified_typed_getters": 0,
    "content_type_substring_checks": 0,
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
    text = (repo / path).read_text(encoding="utf-8")
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
        if sys_getcwd_re.search(line):
            bump("sys_getcwd_calls", path, lineno, raw_line)
        if content_type_substring_re.search(line):
            bump("content_type_substring_checks", path, lineno, raw_line)
        if exception_classifier_re.search(line):
            bump("exception_message_classifiers", path, lineno, raw_line)
        if stub_re.search(line):
            bump("stub_markers", path, lineno, raw_line)
        if wildcard_silent_re.search(line):
            bump("wildcard_silent_defaults", path, lineno, raw_line)

def env_key_aliases(lines):
    aliases = {}
    for line in lines:
        match = env_key_alias_re.search(line)
        if match:
            aliases[match.group(1)] = match.group(2)
    return aliases

def env_alias_refs(aliases, line):
    refs = []
    for match in ident_re.finditer(line):
        env_name = aliases.get(match.group(0))
        if env_name is not None and env_name not in refs:
            refs.append(env_name)
    return refs

def is_env_config_getter_line(line, aliases):
    stripped = line.strip()
    if stripped.startswith(("(*", "*", "let get_", "and get_")):
        return False
    if not (env_config_typed_getter_re.search(stripped) and "~default" in stripped):
        return False
    return bool(env_var_literal_re.search(stripped) or env_alias_refs(aliases, stripped))

def nearby_config_classification(lines, idx, lookback=12):
    start = max(0, idx - lookback)
    nearby = "\n".join(lines[start : idx + 1])
    return category_tag_re.search(nearby), ops_class_tag_re.search(nearby)

for path in tracked:
    if not env_config_path_re.match(path):
        continue
    lines = (repo / path).read_text(encoding="utf-8").splitlines()
    aliases = env_key_aliases(lines)
    for idx, line in enumerate(lines):
        if not is_env_config_getter_line(line, aliases):
            continue
        category, ops_class = nearby_config_classification(lines, idx)
        if category is None or ops_class is None:
            bump("env_config_unclassified_typed_getters", path, idx + 1, line)

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
try:
    print(data["metrics"][metric])
except KeyError:
    print(f"[hardening-ratchet] missing baseline metric: {metric}", file=sys.stderr)
    raise SystemExit(2)
PYEOF
}

metric_is_critical() {
  local metric="$1"
  python3 - "$BASELINE_FILE" "$metric" <<'PYEOF'
import json
import sys

path, metric = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
policy = data.get("metricPolicies", {}).get(metric, {})
accepted = bool(policy.get("acceptedRisk", False))
severity = str(policy.get("severity", "critical")).lower()
print("1" if (not accepted or severity == "critical") else "0")
PYEOF
}

write_json_report() {
  local mode="$1"
  local fail_policy="$2"
  local status="$3"
  local output_path="$4"
  local current_json="$5"
  local current_tmp

  mkdir -p "$(dirname "$output_path")"
  current_tmp="$(mktemp "${TMPDIR:-/tmp}/hardening-current.XXXXXX.json")"
  printf '%s\n' "$current_json" > "$current_tmp"
  python3 - "$BASELINE_FILE" "$mode" "$fail_policy" "$status" "$output_path" "$current_tmp" <<'PYEOF'
import json
import subprocess
import sys
from pathlib import Path

baseline_path, mode, fail_policy, status, output_path, current_path = sys.argv[1:]
with open(current_path) as f:
    current = json.load(f)
with open(baseline_path) as f:
    baseline = json.load(f)

policies = baseline.get("metricPolicies", {})
metric_report = {}
blocking_failures = []
accepted_risk_increases = []

for metric, current_value in sorted(current.get("metrics", {}).items()):
    baseline_value = baseline.get("metrics", {}).get(metric, 0)
    delta = current_value - baseline_value
    policy = policies.get(metric, {})
    accepted_risk = bool(policy.get("acceptedRisk", False))
    severity = str(policy.get("severity", "critical")).lower()
    critical = (not accepted_risk) or severity == "critical"
    increased = delta > 0
    blocking = increased and (fail_policy == "all" or critical)
    if blocking:
        blocking_failures.append(metric)
    elif increased:
        accepted_risk_increases.append(metric)
    metric_report[metric] = {
        "baseline": baseline_value,
        "current": current_value,
        "delta": delta,
        "severity": severity,
        "acceptedRisk": accepted_risk,
        "critical": critical,
        "blocking": blocking,
        "examples": current.get("examples", {}).get(metric, []),
    }

try:
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
except Exception:
    head = None

report = {
    "schemaVersion": 1,
    "tool": "scripts/hardening-ratchet.sh",
    "mode": mode,
    "failPolicy": fail_policy,
    "status": status,
    "head": head,
    "baselineFile": str(Path(baseline_path)),
    "baselineCommit": baseline.get("lastUpdatedCommit"),
    "owner": baseline.get("owner"),
    "blockingFailures": blocking_failures,
    "acceptedRiskIncreases": accepted_risk_increases,
    "metrics": metric_report,
}

with open(output_path, "w") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF
  rm -f "$current_tmp"
}

do_check() {
  local mode="${1:-blocking}"
  local fail_policy="${2:-all}"
  local json_out="${3:-}"
  if [ ! -f "$BASELINE_FILE" ]; then
    echo "[hardening-ratchet] missing baseline: $BASELINE_FILE" >&2
    exit 2
  fi

  local current_json failed increased
  current_json="$(measure)"
  failed=0
  increased=0

  echo "Hardening ratchet"
  printf "%-42s %10s %10s %s\n" "metric" "baseline" "current" "verdict"
  printf "%-42s %10s %10s %s\n" "------------------------------------------" "--------" "-------" "-------"

  for metric in \
    local_workspace_path_literals \
    sys_getcwd_calls \
    direct_env_reads \
    direct_env_reads_outside_env_boundary \
    env_config_unclassified_typed_getters \
    content_type_substring_checks \
    exception_message_classifiers \
    stub_markers \
    wildcard_silent_defaults
  do
    local current baseline verdict critical
    current="$(printf '%s\n' "$current_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["metrics"][sys.argv[1]])' "$metric")"
    baseline="$(baseline_value "$metric")"
    critical="$(metric_is_critical "$metric")"
    if [ "$current" -gt "$baseline" ]; then
      increased=1
      if [ "$fail_policy" = "critical" ] && [ "$critical" = "0" ]; then
        verdict="WARN (+$((current - baseline)) accepted-risk)"
      else
        verdict="FAIL (+$((current - baseline)))"
        failed=1
      fi
    elif [ "$current" -lt "$baseline" ]; then
      verdict="OK (decreased -$((baseline - current)))"
    else
      verdict="OK (held)"
    fi
    printf "%-42s %10s %10s %s\n" "$metric" "$baseline" "$current" "$verdict"
  done

  local status
  if [ "$failed" -ne 0 ]; then
    if [ "$mode" = "advisory" ]; then
      status="advisory_failed"
    else
      status="failed"
    fi
  else
    status="ok"
  fi

  if [ -n "$json_out" ]; then
    write_json_report "$mode" "$fail_policy" "$status" "$json_out" "$current_json"
    echo "[hardening-ratchet] wrote JSON report: $json_out"
  fi

  if [ "$increased" -ne 0 ]; then
    echo
    if [ "$mode" = "advisory" ]; then
      echo "[hardening-ratchet] ADVISORY - one or more hardening metrics increased."
    elif [ "$failed" -ne 0 ]; then
      echo "[hardening-ratchet] FAIL - one or more hardening metrics increased."
    else
      echo "[hardening-ratchet] OK - only accepted-risk hardening metrics increased under --fail-on-critical."
    fi
    echo "$current_json" | python3 -c 'import json,sys
data=json.load(sys.stdin)
for metric, items in data["examples"].items():
    if items:
        print(f"\n[{metric} examples]")
        for item in items:
            print(item)
'
    if [ "$mode" = "advisory" ]; then
      return 0
    fi
    if [ "$failed" -ne 0 ]; then
      exit 1
    fi
    return 0
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
try:
    with open(path) as f:
        existing = json.load(f)
except FileNotFoundError:
    existing = {}
for key in ("owner", "rebaselineCadence", "exemptionProcess", "metricPolicies"):
    if key in existing:
        data[key] = existing[key]
data["_comment"] = "Production hardening ratchet baseline. Regenerate with scripts/hardening-ratchet.sh --rebaseline."
data["lastUpdatedCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
with open(path, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"[hardening-ratchet] wrote {path}")
' "$BASELINE_FILE"
}

usage() {
  echo "usage: $0 [--measure | --check [--advisory] [--fail-on-critical] [--json-out <path>] | --rebaseline]" >&2
}

case "${1:---check}" in
  --measure) measure ;;
  --check)
    shift
    mode="blocking"
    fail_policy="all"
    json_out=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --advisory)
          mode="advisory"
          ;;
        --fail-on-critical)
          fail_policy="critical"
          ;;
        --json-out)
          if [ "$#" -lt 2 ]; then
            usage
            exit 2
          fi
          json_out="$2"
          shift
          ;;
        *)
          usage
          exit 2
          ;;
      esac
      shift
    done
    do_check "$mode" "$fail_policy" "$json_out"
    ;;
  --rebaseline) do_rebaseline ;;
  -h|--help) sed -n '2,30p' "$0" ;;
  *)
    usage
    exit 2
    ;;
esac
