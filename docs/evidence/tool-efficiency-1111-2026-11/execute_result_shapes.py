#!/usr/bin/env python3
"""Where the result bytes of Execute calls go, by command family and by `gh api` endpoint.

Read-only. Reads the ledger through ledger_window.py of the 1110 folder and writes nothing.

Usage:
    python3 -I docs/evidence/tool-efficiency-1111-2026-11/execute_result_shapes.py SINCE_ISO END_ISO [BASE_PATH]

The command text of a call is its `input.command`, or its `input.argv` (the script after `sh -c` / `bash -lc`,
else the words joined). Classification is by that text, so it says what the command line contains, not what the
command did. A command line that contains `gh <subcommand>` at a command boundary (start, or after `;`, `&&`,
`||`, `|`, `(`, `{`, a backtick, a newline, `do`, `then`) belongs to the family `gh <subcommand>` of its first
such occurrence, so `date -u; gh api ...` is a `gh api` call. Any other command line belongs to the family of its
first two words after leading `cd X &&`, `export ...;`, `set ...;` and `VAR=value` prefixes.
"""

from __future__ import annotations

import dataclasses
import json
import pathlib
import re
import shlex
import statistics
import sys
from collections.abc import Iterable, Mapping

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "tool-efficiency-1110-2026-11"))

import ledger_window as ledger  # noqa: E402

TOOL = "Execute"
TOP_FAMILIES = 15
TOP_ENDPOINTS = 15
P90 = 0.9
SHELLS = ("sh", "bash", "zsh")
SHELL_SCRIPT_FLAG = re.compile(r"-[a-z]*c")
PREFIX = re.compile(
    r"^\s*(?:cd\s+\S+\s*(?:&&|;)\s*|export\s+[^;&]+(?:&&|;)\s*|set\s+[^;&]+(?:&&|;)\s*|[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+"
)
GH_SUBCOMMAND = re.compile(
    r"(?:^|[;&|({`\n]|\bdo\b|\bthen\b)\s*gh\s+(?:(?:-R|--repo)\s+\S+\s+)?(?P<sub>[a-z][a-z-]*)"
)
REPO_PREFIX = re.compile(r"^/?repos/[^/]+/[^/]+/")
DIGITS = re.compile(r"\d+")
# `gh api` flags that take the next word as their value, so that word is not the endpoint.
VALUE_FLAGS = frozenset(
    {"-H", "--header", "-X", "--method", "-f", "-F", "--field", "--raw-field", "-q", "--jq", "-t", "--template",
     "--input", "--hostname", "-p", "--preview", "--cache"}
)
JQ_FLAGS = frozenset({"-q", "--jq"})
OPERATOR_CHARS = frozenset("();<>|&")


@dataclasses.dataclass(frozen=True, slots=True)
class Call:
    ts: float
    command: str
    result_bytes: int


@dataclasses.dataclass(frozen=True, slots=True)
class Tally:
    calls: int
    result_bytes: int
    median: float
    p90: int
    maximum: int


@dataclasses.dataclass(frozen=True, slots=True)
class GhApiEndpoint:
    path: str
    filtered_with_jq: bool


def command_of(tool_input: object) -> str | None:
    """`command`, or `argv` (the script after `sh -c` / `bash -lc`, else the words joined); None if neither parses."""
    if not isinstance(tool_input, dict):
        return None
    command = tool_input.get("command")
    if isinstance(command, str):
        return command
    argv = tool_input.get("argv")
    if not isinstance(argv, list) or not argv or not all(isinstance(word, str) for word in argv):
        return None
    if len(argv) >= 3 and argv[0] in SHELLS and SHELL_SCRIPT_FLAG.fullmatch(argv[1]):
        return argv[2]
    return " ".join(argv)


def call_of(row: ledger.Row) -> Call | None:
    ts, size = row.get("ts"), row.get("result_bytes")
    command = command_of(row.get("input"))
    if row.get("tool") != TOOL or not isinstance(ts, (int, float)) or command is None:
        return None
    if not isinstance(size, int) or isinstance(size, bool) or size < 0:
        return None
    return Call(float(ts), command, size)


def family_of(command: str) -> str:
    gh = GH_SUBCOMMAND.search(command)
    if gh is not None:
        return f"gh {gh['sub']}"
    words = PREFIX.sub("", command, count=1).split()
    return " ".join(words[:2]) if words else "(empty)"


def shell_words(text: str) -> list[str]:
    """Words of a shell text with `;`, `&&`, `|`, `(`, `)` and redirections as words of their own. Raises ValueError on a bad quote."""
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    return list(lexer)


def is_operator(word: str) -> bool:
    return all(char in OPERATOR_CHARS for char in word)


def gh_api_endpoint(command: str) -> GhApiEndpoint | None:
    """The endpoint of the first `gh api` in the command line, repo prefix dropped and numbers written as N."""
    start = re.search(r"\bgh\s+api\b", command)
    if start is None:
        return None
    try:
        words = shell_words(command[start.end():])
    except ValueError:
        return None
    path: str | None = None
    jq = False
    skip_value = False
    for word in words:
        if is_operator(word):
            break
        if skip_value:
            skip_value = False
            continue
        if word in JQ_FLAGS or word.startswith("--jq="):
            jq = True
        if word in VALUE_FLAGS:
            skip_value = True
        elif word.startswith("-"):
            continue
        elif path is None:
            path = word.split("?", 1)[0]
    if path is None:
        return None
    return GhApiEndpoint(DIGITS.sub("N", REPO_PREFIX.sub("", path)), jq)


def tally(sizes: list[int]) -> Tally:
    ordered = sorted(sizes)
    return Tally(
        calls=len(ordered),
        result_bytes=sum(ordered),
        median=statistics.median(ordered),
        p90=ordered[min(len(ordered) - 1, int(len(ordered) * P90))],
        maximum=ordered[-1],
    )


def measure(calls: Iterable[Call], since: float, end: float) -> dict[str, object]:
    by_family: dict[str, list[int]] = {}
    by_endpoint: dict[tuple[str, bool], list[int]] = {}
    for call in calls:
        if not since <= call.ts < end:
            continue
        by_family.setdefault(family_of(call.command), []).append(call.result_bytes)
        endpoint = gh_api_endpoint(call.command)
        if endpoint is not None:
            by_endpoint.setdefault((endpoint.path, endpoint.filtered_with_jq), []).append(call.result_bytes)
    total = sum(sum(sizes) for sizes in by_family.values())
    gh_bytes = sum(sum(sizes) for family, sizes in by_family.items() if family.startswith("gh "))
    api_bytes = sum(sum(sizes) for sizes in by_endpoint.values())
    api_jq_bytes = sum(sum(sizes) for (_, jq), sizes in by_endpoint.items() if jq)
    return {
        "calls": sum(len(sizes) for sizes in by_family.values()),
        "result_bytes": total,
        "gh_family_bytes": gh_bytes,
        "gh_family_pct": pct(gh_bytes, total),
        "gh_api_bytes": api_bytes,
        "gh_api_with_jq_bytes": api_jq_bytes,
        "gh_api_without_jq_bytes": api_bytes - api_jq_bytes,
        "families": rank(by_family, total, TOP_FAMILIES, lambda key: {"family": key}),
        "gh_api_endpoints": rank(
            by_endpoint, total, TOP_ENDPOINTS, lambda key: {"endpoint": key[0], "filtered_with_jq": key[1]}
        ),
    }


def pct(part: int, whole: int) -> float | None:
    return round(100.0 * part / whole, 1) if whole else None


def rank(groups: Mapping, total: int, top: int, label) -> list[dict[str, object]]:
    ranked = sorted(groups.items(), key=lambda item: sum(item[1]), reverse=True)[:top]
    out = []
    for key, sizes in ranked:
        t = tally(sizes)
        out.append(
            {
                **label(key),
                "calls": t.calls,
                "result_bytes": t.result_bytes,
                "pct_of_execute_bytes": pct(t.result_bytes, total),
                "median": t.median,
                "p90": t.p90,
                "max": t.maximum,
            }
        )
    return out


def unparsed_in_window(rows: Iterable[ledger.Row], since: float, end: float) -> int:
    """Execute rows with since <= ts < end that `call_of` cannot read (no `command` or `argv`, or no result size)."""
    return sum(
        1
        for row in rows
        if isinstance(row.get("ts"), (int, float)) and since <= row["ts"] < end and call_of(row) is None
    )


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        return 2
    since, end = ledger.parse_utc(argv[1]), ledger.parse_utc(argv[2])
    base = pathlib.Path(argv[3]) if len(argv) == 4 else pathlib.Path.home() / "me"
    rows = [row for row in ledger.read_rows(base, since, end, (f'"tool":"{TOOL}"',)) if row.get("tool") == TOOL]
    calls = [c for c in map(call_of, rows) if c is not None]
    result = measure(calls, since, end)
    result["rows_without_command_or_size"] = unparsed_in_window(rows, since, end)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
