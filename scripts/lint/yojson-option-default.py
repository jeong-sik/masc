#!/usr/bin/env python3
"""Lint: every `'a option` field in a `[@@deriving yojson]` type must carry
[@default None] (or the equivalent [@yojson.option]).

Closes the silent-failure class behind #10356, #10450, #10463.

ppx_deriving_yojson treats a missing optional field as a hard error. When a
producer elides the key (or sets it to `null` and the field type is not
plain `_ option`), the strict decoder fails. Calling code typically logs
`Eio.traceln "drop"` and discards the record — a silent failure. The fix
is to annotate every option field so the derived decoder maps both `null`
and missing keys to None.

This linter parses .ml/.mli files line-oriented (no full OCaml AST) and
flags violations. Runs in CI; baseline violations are pinned in
`.lint/yojson-option-default-baseline.txt` and ratcheted toward zero.

Usage:
  scripts/lint/yojson-option-default.py [--baseline FILE] [--update-baseline]

Exit codes:
  0  no new violations vs. baseline
  1  new violations introduced (fail CI)
  2  baseline regenerated (use with --update-baseline)
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
LIB_DIR = REPO_ROOT / "lib"
DEFAULT_BASELINE = (
    REPO_ROOT / "scripts" / "lint" / "yojson-option-default.allowlist"
)

DERIVING_BLOCK_RE = re.compile(r"\[@@deriving([^]]*)\]")
# Decoders that consume incoming JSON and therefore must handle missing keys.
# Encoder-only derivers (`to_yojson`) cannot fail on a missing optional field
# because there is no decode path. Whole-token match against the deriver list
# avoids false-positives like `to_yojson` accidentally matching `\byojson\b`
# (Python's `\b` happens to treat `_y` as non-boundary because `_` is a word
# character, but relying on that quirk is fragile — parse the comma-separated
# token list explicitly).
DECODING_DERIVERS = frozenset({"yojson", "of_yojson"})
TYPE_START_RE = re.compile(r"^\s*(?:type|and)\s+\w")
OPTION_FIELD_RE = re.compile(
    r"^\s*([\w']+)\s*:\s*[^;]*\boption\b[^;]*;"
)
DEFAULT_NONE_RE = re.compile(r"\[@default\s+None\s*\]")
YOJSON_OPTION_RE = re.compile(r"\[@yojson\.option\]")


def _has_decoding_deriver(text: str) -> bool:
    """True iff text contains a `[@@deriving ...]` block whose comma-separated
    token list includes `yojson` or `of_yojson` as a whole token. Encoder-only
    derivers like `to_yojson` are exempt because they cannot fail on a missing
    optional key (no decode path exists).

    Per-deriver options like `{strict = false}` are tolerated by stripping
    everything up to the first whitespace/brace.
    """
    for match in DERIVING_BLOCK_RE.finditer(text):
        body = match.group(1)
        for raw in body.split(","):
            token = raw.strip()
            if not token:
                continue
            # Trim ppx options: `yojson { strict = false }` -> `yojson`.
            head = re.split(r"[\s{(]", token, maxsplit=1)[0]
            if head in DECODING_DERIVERS:
                return True
    return False


@dataclass(frozen=True)
class Violation:
    file: str
    line: int
    field: str
    type_name: str

    def render(self) -> str:
        return f"{self.file}:{self.line}: {self.type_name}.{self.field}"


def _scan_file(path: Path) -> list[Violation]:
    """Walk a single .ml/.mli file. We keep state for the current type
    block: name, start line, accumulated body, and whether [@@deriving yojson]
    has been seen for that block. A type block ends when we hit either
    [@@deriving ...] (terminal attribute) or a blank line followed by a
    non-indented declaration.

    The parsing is intentionally conservative: we only flag option fields
    when we are confident the enclosing type carries a yojson deriver.
    """

    rel = path.relative_to(REPO_ROOT).as_posix()
    src = path.read_text(encoding="utf-8", errors="replace").splitlines()

    violations: list[Violation] = []

    # State machine over the file: when we see `type X = {` (or variant
    # inline records), accumulate fields until we close the block. Then
    # decide based on whether [@@deriving yojson] is present.
    in_block = False
    block_start = 0
    block_type_name = ""
    block_lines: list[tuple[int, str]] = []

    def flush(end_line: int) -> None:
        nonlocal in_block
        if not in_block:
            return
        joined = "\n".join(line for _, line in block_lines)
        if _has_decoding_deriver(joined):
            for ln, line in block_lines:
                m = OPTION_FIELD_RE.match(line)
                if not m:
                    continue
                field = m.group(1)
                # Look on this line and the next 1-2 lines for an
                # acceptable annotation (some authors put it after
                # the semicolon comment).
                window = "\n".join(line for _, line in block_lines[
                    max(0, block_lines.index((ln, line)) - 0) :
                    min(len(block_lines), block_lines.index((ln, line)) + 2)
                ])
                if DEFAULT_NONE_RE.search(window) or YOJSON_OPTION_RE.search(window):
                    continue
                violations.append(
                    Violation(
                        file=rel,
                        line=ln,
                        field=field,
                        type_name=block_type_name or "?",
                    )
                )
        in_block = False
        block_lines.clear()

    type_decl_re = re.compile(r"^\s*(?:type|and)\s+(?:\w+\s+)?(\w+)\s*[:=]")

    i = 0
    while i < len(src):
        line = src[i]

        if not in_block:
            m = type_decl_re.match(line)
            if m:
                in_block = True
                block_start = i + 1
                block_type_name = m.group(1)
                block_lines = [(i + 1, line)]
                # If the deriving attribute is on the same line, close
                # immediately after.
                if DERIVING_BLOCK_RE.search(line):
                    flush(i + 1)
        else:
            block_lines.append((i + 1, line))
            if DERIVING_BLOCK_RE.search(line):
                flush(i + 1)
            elif line.strip() == "" and i + 1 < len(src):
                nxt = src[i + 1]
                if (
                    nxt
                    and not nxt.startswith(" ")
                    and not nxt.startswith("\t")
                    and nxt.strip() != ""
                    and not nxt.startswith("|")
                ):
                    flush(i + 1)

        i += 1

    flush(len(src))
    return violations


def collect_violations() -> list[Violation]:
    out: list[Violation] = []
    for path in sorted(LIB_DIR.rglob("*.ml")):
        out.extend(_scan_file(path))
    for path in sorted(LIB_DIR.rglob("*.mli")):
        out.extend(_scan_file(path))
    return out


def load_baseline(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return {
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    }


def write_baseline(path: Path, violations: list[Violation]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = "\n".join(sorted(v.render() for v in violations))
    header = (
        "# yojson option-field [@default None] lint baseline.\n"
        "# Generated by scripts/lint/yojson-option-default.py.\n"
        "# Lower this list — never extend it. New violations fail CI.\n"
    )
    path.write_text(header + body + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--baseline",
        type=Path,
        default=DEFAULT_BASELINE,
        help="Baseline file (default: scripts/lint/yojson-option-default.allowlist)",
    )
    parser.add_argument(
        "--update-baseline",
        action="store_true",
        help="Rewrite the baseline to match current violations.",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List every current violation, regardless of baseline.",
    )
    args = parser.parse_args()

    violations = collect_violations()
    rendered = sorted(v.render() for v in violations)

    if args.update_baseline:
        write_baseline(args.baseline, violations)
        print(f"baseline rewritten: {len(violations)} violation(s)", file=sys.stderr)
        return 2

    if args.list:
        for line in rendered:
            print(line)
        print(f"\n[lint] {len(violations)} violation(s) total", file=sys.stderr)
        return 0

    baseline = load_baseline(args.baseline)
    current = set(rendered)

    new_violations = sorted(current - baseline)
    fixed = sorted(baseline - current)

    if new_violations:
        print(
            "[lint] NEW yojson option-field violations (need [@default None]):",
            file=sys.stderr,
        )
        for v in new_violations:
            print(f"  {v}", file=sys.stderr)
        print(
            f"\nFix: add `[@default None]` to each option field above, or run\n"
            f"  scripts/lint/yojson-option-default.py --update-baseline\n"
            f"only if the field genuinely should not carry the annotation\n"
            f"(extremely rare — document the reason in code).",
            file=sys.stderr,
        )
        return 1

    if fixed:
        print(
            f"[lint] {len(fixed)} violation(s) fixed since baseline. "
            f"Refresh with --update-baseline:",
            file=sys.stderr,
        )
        for v in fixed:
            print(f"  - {v}", file=sys.stderr)

    print(
        f"[lint] {len(current)} violation(s) at baseline (no new).",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
