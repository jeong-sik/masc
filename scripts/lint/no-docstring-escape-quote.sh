#!/usr/bin/env bash
# Detect bare backslash-escaped double quotes inside OCaml docstrings.
#
# `(** ... \"foo\" ... *)` puts the OCaml lexer into string mode at
# the backslash-escape (the `\` is literal, then `"` opens a string)
# and consumes through the next unescaped `"` — producing
# "unterminated string literal" reported on a *downstream* line
# (wherever the spurious string finally finds a closing quote).
#
# Inside `(** *)` docstrings the inner content is comment text. The
# OCaml lexer does still scan for string literals inside comments
# (so `["foo"]` is fine — paired quotes), but a *bare* `\"` outside
# any opened string is the bug. This script simulates the lexer's
# string-mode state through each docstring body to flag only the
# bare-escape case (no false positives on legitimate examples like
# `["error: \"key\""]` inside a docstring).
#
# References:
#   - PR #11411 — first occurrence (documented in memory)
#   - PR #11419 introduced second instance in lib/types/severity.mli
#     within hours of the memory entry; fixed by #11447
#   - memory/feedback_ocaml_docstring_escape_quote_lexer_trap.md
#
# Exit codes:
#   0 — clean
#   1 — violation(s) found
#   2 — environment error (python3 missing)

set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found on PATH." >&2
  echo "  On Debian/Ubuntu: sudo apt-get install -y -qq python3" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

python3 - <<'PYEOF'
import re
import sys
import pathlib

# (** ... *) docstring blocks (non-greedy, multi-line).
docstring_re = re.compile(r'\(\*\*(.*?)\*\)', re.DOTALL)


def find_bare_escape_quote(content: str) -> bool:
    """Simulate the OCaml lexer's string-mode state through the docstring
    body. Returns True if any `\\"` occurs outside an opened string
    literal (the lexer trap). `\\"` inside a properly-opened string is
    valid and not flagged."""
    in_string = False
    i = 0
    n = len(content)
    while i < n:
        c = content[i]
        if not in_string:
            # Bare \" outside string opens a spurious string.
            if c == '\\' and i + 1 < n and content[i + 1] == '"':
                return True
            if c == '"':
                in_string = True
        else:
            # Inside a string: skip any escape sequence whole.
            if c == '\\' and i + 1 < n:
                i += 2
                continue
            if c == '"':
                in_string = False
        i += 1
    return False


violations = []
for root in ('lib', 'test', 'bin'):
    p = pathlib.Path(root)
    if not p.exists():
        continue
    for path in sorted(list(p.rglob('*.ml')) + list(p.rglob('*.mli'))):
        try:
            text = path.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            continue
        for m in docstring_re.finditer(text):
            if find_bare_escape_quote(m.group(1)):
                line = text.count('\n', 0, m.start()) + 1
                snippet_lines = [ln.strip() for ln in m.group(1).splitlines() if ln.strip()]
                snippet = (snippet_lines[0] if snippet_lines else '')[:100]
                violations.append((str(path), line, snippet))

if violations:
    print(f"Found {len(violations)} OCaml docstring(s) with bare escape-quote:",
          file=sys.stderr)
    print("", file=sys.stderr)
    for path, line, snippet in violations:
        print(f'::error file={path},line={line}::docstring escape: '
              'a bare backslash-escaped quote in (** *) puts the OCaml lexer '
              'into string mode and consumes through the next unescaped " '
              '(use plain "..." inside docstrings, not \\"...\\")',
              file=sys.stderr)
        print(f"  {path}:{line}: {snippet}", file=sys.stderr)
    print("", file=sys.stderr)
    print("Why this is a bug:", file=sys.stderr)
    print("  Backslash escaping is for *real* string literals. Inside (** *)",
          file=sys.stderr)
    print("  docstrings the content is comment text — `\\\"` is read as a",
          file=sys.stderr)
    print("  literal `\\` followed by `\"`, which opens a string. The lexer",
          file=sys.stderr)
    print("  then consumes everything until the next unescaped `\"`,",
          file=sys.stderr)
    print("  producing 'unterminated string literal' on a downstream line.",
          file=sys.stderr)
    print("", file=sys.stderr)
    print('Fix: replace `\\"foo\\"` with plain `"foo"` inside `(** *)`.',
          file=sys.stderr)
    print("", file=sys.stderr)
    print("Note: docstrings *can* legitimately contain string literals (e.g.",
          file=sys.stderr)
    print("`[\"key\"]` or `[\"error: \\\"k\\\"\"]`). This script simulates the",
          file=sys.stderr)
    print("lexer's string-mode state and only flags *bare* `\\\"` outside",
          file=sys.stderr)
    print("any opened string — no false positives on legitimate examples.",
          file=sys.stderr)
    print("", file=sys.stderr)
    print("References: PR #11411, PR #11419/#11447,", file=sys.stderr)
    print("  memory/feedback_ocaml_docstring_escape_quote_lexer_trap.md",
          file=sys.stderr)
    sys.exit(1)

print("No OCaml docstring bare-escape-quote violations found.")
PYEOF
