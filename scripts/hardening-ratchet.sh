#!/usr/bin/env bash
# Production hardening ratchet for OAS.
#
# This is a monotone-decrease companion to the RFC-OAS-022 code-smell ratchet.
# It intentionally runs through the existing ratchet workflow so waiver,
# branch, and reporting policy remain centralized.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BASELINE_FILE="${REPO_ROOT}/.ci/hardening-baseline.json"
CONFIG_FILE="${REPO_ROOT}/.ci/hardening-ratchet-config.json"
cd "$REPO_ROOT"

run_python() {
  local mode="$1"
  python3 - "$REPO_ROOT" "$CONFIG_FILE" "$BASELINE_FILE" "$mode" <<'PYEOF'
import json
import os
import re
import subprocess
import sys
from pathlib import Path

METRICS = (
    "local_workspace_path_literals",
    "direct_env_reads",
    "direct_env_reads_outside_env_boundary",
    "exception_message_classifiers",
    "heuristic_markers",
    "workaround_markers",
    "model_id_string_classifiers_outside_catalog",
    "base_url_host_fuzzy_classifiers",
    "stub_markers",
    "wildcard_silent_defaults",
)

ENV_READ_RE = re.compile(r"\b(?:Sys|Unix)\.(?:getenv|getenv_opt|unsafe_getenv)\b")
EXCEPTION_CLASSIFIER_RE = re.compile(
    r"\bclassify_by_message\b"
    r"|String\.lowercase_ascii\s+(?:msg|message|\([^)]*(?:msg|message|Printexc\.to_string)[^)]*\))"
    r"|\bhas_substr\s+(?:msg|message|m)\b"
)
HEURISTIC_MARKER_RE = re.compile(r"\bheuristic(?:s|al)?(?:\b|_)")
WORKAROUND_MARKER_RE = re.compile(r"\bworkaround(?:\b|_)")
MODEL_ID_STRING_CLASSIFIER_RE = re.compile(
    r"\bString\.(?:lowercase_ascii|uppercase_ascii|starts_with|ends_with|contains|equal)\b"
    r".*\b(?:config\.)?model(?:_id)?\b"
    r"|\b(?:config\.)?model(?:_id)?\b"
    r".*\bString\.(?:lowercase_ascii|uppercase_ascii|starts_with|ends_with|contains|equal)\b"
    # Delegated model-id prefix classification: calling the Zai_catalog GLM
    # prefix classifier outside the catalog/capability boundary is the same
    # SSOT drift as inlining String.starts_with on a model id, but the lexical
    # String.* patterns above cannot see the delegation (RFC-OAS-023/029;
    # the api_openai.ml is_glm_request removal is the reference cleanup).
    r"|\bis_glm_model_id\b"
)
# Fuzzy string classification of a base_url / host, forbidden by RFC-OAS-034
# (host/URL is transport, not capability provenance). Only the inexact matchers
# are flagged: [String.equal] is intentionally excluded because exact
# [Uri.host] equality is the sanctioned way to bind a vendor-canonical host to a
# provider identity. Normalisation-only calls ([lowercase_ascii]/[trim]) are not
# classifiers and are excluded too. New matches must migrate to exact host
# equality or a model-catalog capability binding.
#
# [Uri.host ...] is tracked as an equivalent host token (not just the bare
# identifiers [host]/[base_url]) so fuzzy matching performed directly on a
# freshly-extracted `Uri.host` value -- without first binding it to a `host`-
# named variable -- is still caught.
# The gap between the matcher and the host token is a "tempered dot": it spans
# arbitrary text but stops at OCaml statement/branch/tuple separators.
# Without this bound the greedy `.*` matched across independent statements on
# one physical line -- e.g. `let host = Uri.host uri in
# String.starts_with ~prefix:"qwen" model_id` counted as a host classifier even
# though the classifier operates on `model_id`, not the host binding that
# precedes it. Genuine same-statement classifiers (including `host |> String.x`
# pipelines) contain no separator between the tokens and still match.
_HOST_FUZZY_GAP = r"(?:(?!\b(?:in|let|then|else)\b|[;,]|->).)*"
HOST_URL_FUZZY_CLASSIFIER_RE = re.compile(
    r"\bString\.(?:starts_with|ends_with|contains|is_substring)\b"
    + _HOST_FUZZY_GAP
    + r"\b(?:base_url|host|Uri\.host)\b"
    r"|\b(?:base_url|host|Uri\.host)\b"
    + _HOST_FUZZY_GAP
    + r"\bString\.(?:starts_with|ends_with|contains|is_substring)\b"
)
STRING_MATCHER_RE = re.compile(
    r"\bString\.(?:starts_with|ends_with|contains|is_substring)\b"
)
# ocamlformat breaks a long matcher application across lines, leaving the
# host/base_url argument one or two physical lines below the callee. Two split
# shapes end a line "dangling" (the call is not yet complete): the bare callee
# alone (`String.ends_with`), or the callee plus a labelled argument with the
# haystack still pending (`String.ends_with ~suffix:sfx`). host_fuzzy_classifier_hit
# joins forward only while the accumulated text stays dangling AND still holds a
# String matcher, bounded to MAX_HOST_FUZZY_JOIN extra lines, so two unrelated
# adjacent statements are never stitched together (an earlier attempt to join on
# a dangling bare identifier was reverted for exactly that false-join reason).
MAX_HOST_FUZZY_JOIN = 2
HOST_FUZZY_DANGLING_RE = re.compile(
    r"\bString\.(?:starts_with|ends_with|contains|is_substring)\s*$"
    r"|~\w+:[^\s,)\]}]+\s*$"
)
STUB_RE = re.compile(
    r"\bNot_implemented\b"
    r"|failwith\s+\"[^\"]*(?:not implemented|TODO|stub)[^\"]*\""
)
WILDCARD_SILENT_RE = re.compile(
    r"^\s*\|\s*_\s*->\s*(?:Ok\b|None\b|\[\]|\(\)|true\b|false\b|\"\")"
)
STRING_LITERAL_RE = re.compile(r"\"(?:\\.|[^\"\\])*\"")


def load_json(path: Path):
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def load_config(path: Path):
    data = load_json(path)
    required = {
        "sourceRoots",
        "sourceSuffixes",
        "excludedPathParts",
        "envBoundaryPaths",
        "modelStringClassifierBoundaryPaths",
        "forbiddenLocalPathPrefixes",
        "maxExamples",
        "removalTargets",
    }
    missing = sorted(required - set(data))
    if missing:
        raise SystemExit(f"[hardening-ratchet] config missing keys: {missing}")
    return data


def tracked_runtime_files(repo: Path, config):
    tracked = subprocess.check_output(["git", "ls-files"], cwd=repo, text=True).splitlines()
    source_roots = tuple(config["sourceRoots"])
    source_suffixes = tuple(config["sourceSuffixes"])
    excluded = set(config["excludedPathParts"])
    return [
        p for p in tracked
        if p.startswith(source_roots)
        and p.endswith(source_suffixes)
        and not any(part in excluded for part in p.split("/"))
    ]


def uncomment_lines(text: str):
    comment_depth = 0
    in_string = False
    escaped = False
    for raw in text.splitlines():
        out = []
        i = 0
        while i < len(raw):
            ch = raw[i]
            pair = raw[i:i + 2]
            if comment_depth > 0:
                if pair == "(*":
                    comment_depth += 1
                    i += 2
                elif pair == "*)":
                    comment_depth -= 1
                    i += 2
                else:
                    i += 1
            elif in_string:
                out.append(ch)
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == "\"":
                    in_string = False
                i += 1
            elif pair == "(*":
                comment_depth = 1
                i += 2
            elif ch == "\"":
                in_string = True
                out.append(ch)
                i += 1
            elif ch == "'":
                end = i + 1
                char_escaped = False
                while end < len(raw):
                    c = raw[end]
                    if char_escaped:
                        char_escaped = False
                    elif c == "\\":
                        char_escaped = True
                    elif c == "'":
                        break
                    end += 1
                if end < len(raw) and 1 < (end - i) <= 8:
                    out.append(raw[i:end + 1])
                    i = end + 1
                else:
                    out.append(ch)
                    i += 1
            else:
                out.append(ch)
                i += 1
        yield "".join(out), raw
    if comment_depth != 0:
        raise ValueError("unterminated OCaml comment")
    if in_string:
        raise ValueError("unterminated OCaml string literal")


def is_env_boundary(path: str, config) -> bool:
    boundary_paths = set(config["envBoundaryPaths"])
    return path in boundary_paths


def is_model_string_classifier_boundary(path: str, config) -> bool:
    boundary_paths = set(config["modelStringClassifierBoundaryPaths"])
    return path in boundary_paths


def has_local_workspace_literal(line: str, config) -> bool:
    prefixes = tuple(config["forbiddenLocalPathPrefixes"])
    for match in STRING_LITERAL_RE.finditer(line):
        literal = match.group(0)[1:-1]
        if any(prefix in literal for prefix in prefixes):
            return True
    return False


def mask_string_literals(line: str) -> str:
    return STRING_LITERAL_RE.sub("\"\"", line)


def empty_result(config):
    metrics = {key: 0 for key in METRICS}
    examples = {key: [] for key in METRICS}
    return metrics, examples, int(config["maxExamples"])


def bump(metrics, examples, max_examples, metric: str, path: str, lineno: int, line: str) -> None:
    metrics[metric] += 1
    if len(examples[metric]) < max_examples:
        examples[metric].append(f"{path}:{lineno}:{line.strip()}")


def host_fuzzy_classifier_hit(code_lines, idx):
    """Return True if the (already string-masked) line at 0-based ``idx`` -- on
    its own or once ocamlformat's line-wrapped continuation is stitched back --
    fuzzy-classifies a base_url/host. Forward joins are bounded and only occur
    while the accumulated text still dangles on an incomplete String matcher, so
    two unrelated adjacent statements are never merged into a spurious match."""
    acc = code_lines[idx]
    if HOST_URL_FUZZY_CLASSIFIER_RE.search(acc):
        return True
    joins = 0
    j = idx
    while (
        joins < MAX_HOST_FUZZY_JOIN
        and j + 1 < len(code_lines)
        and STRING_MATCHER_RE.search(acc)
        and HOST_FUZZY_DANGLING_RE.search(acc)
    ):
        j += 1
        acc = f"{acc} {code_lines[j]}"
        joins += 1
        if HOST_URL_FUZZY_CLASSIFIER_RE.search(acc):
            return True
    return False


def measure_texts(files, config):
    metrics, examples, max_examples = empty_result(config)
    for path, text in files.items():
        try:
            lines = list(uncomment_lines(text))
            code_lines = [mask_string_literals(line) for line, _ in lines]
            for lineno, (line, raw_line) in enumerate(lines, 1):
                code_line = code_lines[lineno - 1]
                env_matches = list(ENV_READ_RE.finditer(code_line))
                if env_matches:
                    metrics["direct_env_reads"] += len(env_matches)
                    if len(examples["direct_env_reads"]) < max_examples:
                        examples["direct_env_reads"].append(f"{path}:{lineno}:{raw_line.strip()}")
                    if not is_env_boundary(path, config):
                        metrics["direct_env_reads_outside_env_boundary"] += len(env_matches)
                        if len(examples["direct_env_reads_outside_env_boundary"]) < max_examples:
                            examples["direct_env_reads_outside_env_boundary"].append(
                                f"{path}:{lineno}:{raw_line.strip()}"
                            )
                if has_local_workspace_literal(line, config):
                    bump(metrics, examples, max_examples, "local_workspace_path_literals", path, lineno, raw_line)
                if EXCEPTION_CLASSIFIER_RE.search(code_line):
                    bump(metrics, examples, max_examples, "exception_message_classifiers", path, lineno, raw_line)
                if HEURISTIC_MARKER_RE.search(code_line):
                    bump(metrics, examples, max_examples, "heuristic_markers", path, lineno, raw_line)
                if WORKAROUND_MARKER_RE.search(code_line):
                    bump(metrics, examples, max_examples, "workaround_markers", path, lineno, raw_line)
                if (
                    (not is_model_string_classifier_boundary(path, config))
                    and MODEL_ID_STRING_CLASSIFIER_RE.search(code_line)
                ):
                    bump(
                        metrics,
                        examples,
                        max_examples,
                        "model_id_string_classifiers_outside_catalog",
                        path,
                        lineno,
                        raw_line,
                    )
                # ocamlformat routinely splits a matcher call and its host/
                # base_url argument across physical lines, so neither line alone
                # contains both tokens even though the AST is a fuzzy host match.
                # host_fuzzy_classifier_hit re-stitches only the dangling
                # continuation shapes ocamlformat produces (see its docstring).
                if host_fuzzy_classifier_hit(code_lines, lineno - 1):
                    bump(
                        metrics,
                        examples,
                        max_examples,
                        "base_url_host_fuzzy_classifiers",
                        path,
                        lineno,
                        raw_line,
                    )
                if STUB_RE.search(line):
                    bump(metrics, examples, max_examples, "stub_markers", path, lineno, raw_line)
                if WILDCARD_SILENT_RE.search(line):
                    bump(metrics, examples, max_examples, "wildcard_silent_defaults", path, lineno, raw_line)
        except Exception as exc:
            raise SystemExit(f"[hardening-ratchet] failed to scan {path}: {exc}") from exc
    return {"metrics": metrics, "examples": examples}


def measure_repo(repo: Path, config):
    files = {}
    for path in tracked_runtime_files(repo, config):
        files[path] = (repo / path).read_text(encoding="utf-8", errors="strict")
    return measure_texts(files, config)


def print_measurement(result):
    print(json.dumps(result, indent=2, sort_keys=True))


def check(repo: Path, config, baseline_path: Path):
    if not baseline_path.is_file():
        raise SystemExit(f"[hardening-ratchet] missing baseline: {baseline_path}")
    baseline = load_json(baseline_path)
    current = measure_repo(repo, config)
    failed = False
    print("Hardening ratchet")
    print("Source: docs/rfc/RFC-OAS-023-hardening-ratchet.md")
    print(f"{'metric':42s} {'baseline':>10s} {'current':>10s} verdict")
    print(f"{'-' * 42:42s} {'--------':>10s} {'-------':>10s} -------")
    for metric in METRICS:
        base = int(baseline["metrics"].get(metric, 0))
        cur = int(current["metrics"].get(metric, 0))
        if cur > base:
            verdict = f"FAIL (+{cur - base})"
            failed = True
        elif cur < base:
            verdict = f"OK (decreased -{base - cur})"
        else:
            verdict = "OK (held)"
        print(f"{metric:42s} {base:10d} {cur:10d} {verdict}")
    if failed:
        print()
        print("[hardening-ratchet] FAIL - one or more hardening metrics increased.")
        for metric, items in current["examples"].items():
            if items:
                print(f"\n[{metric} examples]")
                for item in items:
                    print(item)
        return 1
    print()
    print("[hardening-ratchet] OK")
    return 0


def rebaseline(repo: Path, config, baseline_path: Path):
    current_branch = subprocess.check_output(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=repo, text=True
    ).strip()
    if current_branch != "main" and os.environ.get("ALLOW_REBASELINE_OFF_MAIN") != "1":
        raise SystemExit(
            f"refusing to rebaseline off main (branch={current_branch}). "
            "Set ALLOW_REBASELINE_OFF_MAIN=1 to override."
        )
    data = measure_repo(repo, config)
    data["_comment"] = (
        "Production hardening ratchet baseline. Source: "
        "docs/rfc/RFC-OAS-023-hardening-ratchet.md. "
        "Regenerate with scripts/hardening-ratchet.sh --rebaseline."
    )
    data["lastUpdatedCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    data["removalTargets"] = config["removalTargets"]
    baseline_path.parent.mkdir(parents=True, exist_ok=True)
    with baseline_path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"[hardening-ratchet] wrote {baseline_path}")


def self_test(config):
    sample = {
        "lib/runtime.ml": "\n".join([
            "let ignored = \"(* Sys.getenv_opt \\\\\"COMMENT\\\\\" *)\"",
            "(* nested (* Sys.getenv_opt \\\\\"COMMENT\\\\\" *) comment *)",
            "let env = Sys.getenv_opt \\\\\"OAS_DIRECT\\\\\"",
            "let classify_by_message msg = msg",
            "let m = String.lowercase_ascii msg",
            "let choice = heuristic_classify query",
            "let workaround_flag = true",
            "let model_norm = String.lowercase_ascii model_id",
            "let model_is_qwen = String.starts_with ~prefix:\"qwen\" model_id",
            "let is_proxy = String.ends_with ~suffix:sfx host",
            "let host_ok = String.equal host api_host",
            "  String.starts_with",
            "    ~prefix:sfx host",
            "let direct_uri_check = String.ends_with (Uri.host uri) ~suffix:\".ollama.com\"",
            # RFC-OAS-034 detector mutation cases -- guard both failure modes of
            # the line-regex host classifier. FN: ocamlformat wraps the host arg
            # one or two lines below the matcher; the forward join must re-stitch
            # it. Each block counts exactly once (at the callee line).
            "    String.ends_with",
            "      ~suffix:proxy_a",
            "      host",
            "  String.ends_with ~suffix:proxy_b",
            "    host",
            # FP: an unrelated host binding sharing one physical line with a
            # classifier on `model_id` must NOT count -- the tempered gap stops
            # at `in`, so `Uri.host` never reaches `String.starts_with`.
            "let host = Uri.host uri in String.starts_with ~prefix:\"Bearer \" auth_header",
            "let route = if String.contains user_agent ~sub:\"bot\" then host else fallback",
            "let tuple = (String.starts_with ~prefix:\"qwen\" request_name, host)",
            "| Some host -> String.ends_with ~suffix:\"qwen\" request_name",
            "  String.contains user_agent ~sub:bot_name",
            "  then host else fallback",
            "  String.ends_with ~suffix:model_suffix)",
            "  host",
            "| _ -> None",
            "let path = \\\\\"/home/alice/me/tmp\\\\\"",
            "let impossible = assert false",
            "let fixture = \\\\\"connection refused\\\\\"",
        ]),
        "lib/defaults.ml": "let env = Sys.getenv_opt \\\\\"OAS_BOUNDARY\\\\\"",
        "lib/llm_provider/capabilities.ml": "let catalog_model = String.lowercase_ascii model_id",
    }
    result = measure_texts(sample, config)
    expected = {
        "direct_env_reads": 2,
        "direct_env_reads_outside_env_boundary": 1,
        "exception_message_classifiers": 2,
        "heuristic_markers": 1,
        "local_workspace_path_literals": 1,
        "model_id_string_classifiers_outside_catalog": 2,
        # 3 baseline (single-line + 2-line dangling join + Uri.host token) plus 2
        # multi-line wraps re-stitched by the forward join (~suffix on its own
        # line, and a 3-line split). The same-line `Uri.host ... in ... model_id`
        # false positive is deliberately excluded, so a detector that regressed
        # either fix would not land on exactly 5.
        "base_url_host_fuzzy_classifiers": 5,
        "stub_markers": 0,
        "workaround_markers": 1,
        "wildcard_silent_defaults": 1,
    }
    if result["metrics"] != expected:
        print(json.dumps({"expected": expected, "actual": result["metrics"]}, indent=2, sort_keys=True))
        raise SystemExit("[hardening-ratchet] self-test failed")
    print("[hardening-ratchet] self-test OK")


def main(argv):
    if len(argv) != 5:
        raise SystemExit("usage: runner <repo> <config> <baseline> <mode>")
    repo = Path(argv[1])
    config = load_config(Path(argv[2]))
    baseline = Path(argv[3])
    mode = argv[4]
    if mode == "--measure":
        print_measurement(measure_repo(repo, config))
    elif mode == "--check":
        raise SystemExit(check(repo, config, baseline))
    elif mode == "--rebaseline":
        rebaseline(repo, config, baseline)
    elif mode == "--self-test":
        self_test(config)
    else:
        raise SystemExit("usage: scripts/hardening-ratchet.sh [--measure | --check | --rebaseline | --self-test]")


main(sys.argv)
PYEOF
}

mode="${1:---check}"

case "$mode" in
  --measure|--check|--rebaseline|--self-test)
    run_python "$mode"
    ;;
  -h|--help)
    sed -n '2,12p' "$0"
    ;;
  *)
    echo "usage: $0 [--measure | --check | --rebaseline | --self-test]" >&2
    exit 2
    ;;
esac
