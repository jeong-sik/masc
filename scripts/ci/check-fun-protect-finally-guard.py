#!/usr/bin/env python3
"""Diff-scoped guard for risky new Fun.protect finalizers.

#10395 is not solved by counting every historical Fun.protect. The risky class
is a finalizer that can yield, block, or acquire Eio resources while unwinding
cooperative cancellation. This guard prevents new instances of that class while
existing sites are migrated in smaller batches.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


LIB_ML_RE = re.compile(r"^lib/.+\.ml$")
RISK_RE = re.compile(
    r"\b("
    r"Eio\.(?!Cancel\b)"
    r"|Fiber\."
    r"|Promise\.await\b"
    r"|Stream\.(?:take|add|close)\b"
    r"|Condition\.await\b"
    r"|Mutex\.(?:lock|use_|with_)"
    r")"
)
ALLOW_MARKER = "fun-protect-finally-ok"


@dataclass(frozen=True)
class AddedProtect:
    path: str
    line_no: int
    text: str


def run_git_diff(base: str, head: str) -> str:
    result = subprocess.run(
        ["git", "diff", "--unified=0", f"{base}...{head}", "--", "lib"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode not in (0, 1):
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return result.stdout


def added_protects_from_diff(diff_text: str) -> list[AddedProtect]:
    current_path: str | None = None
    new_line_no: int | None = None
    added: list[AddedProtect] = []

    for raw in diff_text.splitlines():
        if raw.startswith("+++ b/"):
            current_path = raw[len("+++ b/") :]
            new_line_no = None
            continue
        if raw.startswith("diff --git "):
            current_path = None
            new_line_no = None
            continue
        if raw.startswith("@@ "):
            match = re.search(r"\+(\d+)(?:,(\d+))?", raw)
            new_line_no = int(match.group(1)) if match else None
            continue
        if current_path is None or new_line_no is None:
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            text = raw[1:]
            if LIB_ML_RE.match(current_path) and "Fun.protect" in text:
                added.append(AddedProtect(current_path, new_line_no, text.strip()))
            new_line_no += 1
        elif raw.startswith("-") and not raw.startswith("---"):
            continue
        else:
            new_line_no += 1
    return added


def read_lines(path: str) -> list[str]:
    try:
        return Path(path).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return []


def extract_finalizer(lines: list[str], line_no: int, window: int = 28) -> str:
    start = max(0, line_no - 1)
    snippet = "\n".join(lines[start : start + window])
    marker = "~finally:"
    marker_idx = snippet.find(marker)
    if marker_idx < 0:
        return ""
    rest = snippet[marker_idx + len(marker) :].lstrip()
    if not rest.startswith("("):
        return rest.splitlines()[0] if rest else ""

    depth = 0
    out: list[str] = []
    for ch in rest:
        out.append(ch)
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                break
    return "".join(out)


def has_allow_marker(lines: list[str], line_no: int) -> bool:
    idx = max(0, line_no - 1)
    start = max(0, idx - 3)
    end = min(len(lines), idx + 8)
    return ALLOW_MARKER in "\n".join(lines[start:end])


def validate_protect(site: AddedProtect) -> str | None:
    lines = read_lines(site.path)
    finalizer = extract_finalizer(lines, site.line_no)
    if not finalizer:
        return None
    if has_allow_marker(lines, site.line_no):
        return None
    match = RISK_RE.search(finalizer)
    if match is None:
        return None
    return (
        f"{site.path}:{site.line_no}: risky Fun.protect finalizer uses "
        f"`{match.group(0)}` near `{site.text}`. Prefer Eio.Switch.on_release "
        f"or add `{ALLOW_MARKER}` with a cancellation-safety rationale."
    )


def check(base: str, head: str) -> int:
    sites = added_protects_from_diff(run_git_diff(base, head))
    failures = [failure for site in sites if (failure := validate_protect(site))]
    if failures:
        print("Fun.protect finalizer guard failed.")
        print("New Fun.protect finalizers must not acquire/yield on Eio resources.")
        print()
        for failure in failures:
            print(failure)
        return 1
    print(f"Fun.protect finalizer guard passed ({len(sites)} new Fun.protect line(s)).")
    return 0


def self_test() -> int:
    diff = """diff --git a/lib/foo.ml b/lib/foo.ml
--- a/lib/foo.ml
+++ b/lib/foo.ml
@@ -1,0 +2,1 @@
+  Fun.protect
diff --git a/test/foo.ml b/test/foo.ml
--- a/test/foo.ml
+++ b/test/foo.ml
@@ -1,0 +2,1 @@
+  Fun.protect
"""
    assert added_protects_from_diff(diff) == [
        AddedProtect("lib/foo.ml", 2, "Fun.protect")
    ]
    risky_lines = [
        "let f mutex g =",
        "  Fun.protect",
        "    ~finally:(fun () ->",
        "      Eio.Mutex.use_rw mutex (fun () -> ()))",
        "    g",
    ]
    finalizer = extract_finalizer(risky_lines, 2)
    assert "Eio.Mutex.use_rw" in finalizer
    assert RISK_RE.search(finalizer)
    safe_lines = [
        "let f ic g =",
        "  Fun.protect ~finally:(fun () -> close_in_noerr ic) g",
    ]
    assert not RISK_RE.search(extract_finalizer(safe_lines, 2))
    print("self-test passed")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    return check(args.base, args.head)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
