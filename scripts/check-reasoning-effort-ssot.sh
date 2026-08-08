#!/usr/bin/env bash
# RFC-OAS-029 S2.2 guard:
# budget -> reasoning-effort thresholds live in Reasoning_effort only.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

python3 - "$REPO_ROOT" <<'PYEOF'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])

TARGETS = [
    # lib/api_openai.ml was retired with the legacy dispatch island (2026-07-21);
    # its reasoning-effort mapping lives on in backend_openai_request.ml below.
    "lib/llm_provider/backend_anthropic.ml",
    "lib/llm_provider/backend_gemini.ml",
    "lib/llm_provider/backend_openai_request.ml",
    "lib/llm_provider/backend_openai_responses.ml",
    "lib/llm_provider/complete_sampling.ml",
    "lib/llm_provider/provider_config.ml",
]

THRESHOLD_RE = re.compile(r"(?<![A-Za-z0-9_])(?:2_?048|8_?192|32_?768)(?![A-Za-z0-9_])")


def uncomment_lines(text: str):
    comment_depth = 0
    in_string = False
    escaped = False
    for raw in text.splitlines():
        out = []
        i = 0
        while i < len(raw):
            ch = raw[i]
            pair = raw[i : i + 2]
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
                out.append(" ")
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_string = False
                i += 1
            elif pair == "(*":
                comment_depth = 1
                i += 2
            elif ch == '"':
                in_string = True
                out.append(" ")
                i += 1
            else:
                out.append(ch)
                i += 1
        yield "".join(out), raw
    if comment_depth != 0:
        raise SystemExit("[reasoning-effort-ssot] unterminated OCaml comment")


violations = []
for rel in TARGETS:
    path = repo / rel
    if not path.is_file():
        raise SystemExit(f"[reasoning-effort-ssot] missing target: {rel}")
    for lineno, (code, raw) in enumerate(uncomment_lines(path.read_text(encoding="utf-8")), 1):
        if THRESHOLD_RE.search(code):
            violations.append(f"{rel}:{lineno}:{raw.strip()}")

if violations:
    print("[reasoning-effort-ssot] FAIL")
    print("Budget-to-effort threshold literals must stay in lib/llm_provider/reasoning_effort.ml.")
    print("Use Reasoning_effort.of_budget / named constants instead.")
    print()
    for item in violations:
        print(item)
    raise SystemExit(1)

print("[reasoning-effort-ssot] OK")
PYEOF
