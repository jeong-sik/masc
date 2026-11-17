#!/usr/bin/env python3
"""List every file-read call site in MASC production OCaml sources.

Scans `lib/` and `bin/` `.ml` files (tests are out of scope) after blanking
comments and string literals, and writes one TSV row per primitive match.

Each primitive carries attributes read from its implementation on
origin/main 0542d471eedf5 (2026-11-17):
- shape: whole | lines | slice | stream | tail | range | dir | meta | db
- mech: where the blocking read runs
    systhread_host  Fs_compat wrapper; inside an Eio fiber it hops to the
                    single Systhread_host domain, outside Eio it runs inline
    read_pool       Dated_jsonl job via Domain_pool_ref.submit_io_or_inline
    caller          blocks the calling domain (Stdlib channel, Unix, Sys, SQLite)
    eio             eio_posix: open/stat/readdir on a systhread, read inline
- lock: per-path append mutex held during the read, when the wrapper takes it

The enclosing binding is the nearest preceding `let`/`and` with indentation
of at most two spaces; it locates the site, it does not name the caller.
`wrap_*` columns report whether the enclosing binding text itself mentions a
submission or cache wrapper; the outermost submission is usually a caller.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class Primitive:
    pid: str
    pattern: re.Pattern[str]
    shape: str
    mech: str
    lock: str


def prim(pid: str, regex: str, shape: str, mech: str, lock: str = "-") -> Primitive:
    return Primitive(pid, re.compile(regex), shape, mech, lock)


# Order matters: the first matching primitive on a span wins, so specific
# wrappers come before the generic OS calls they are built from.
PRIMITIVES: tuple[Primitive, ...] = (
    prim("fs.load_jsonl", r"\bFs_compat\.load_jsonl(_diagnostics)?\b", "whole+parse", "systhread_host", "append_mutex"),
    prim("fs.read_file_under_append_mutex", r"\bFs_compat\.read_file_under_append_mutex\b", "whole", "systhread_host", "append_mutex"),
    prim("fs.load_file_locked", r"\bFs_compat\.load_file_locked(_with)?\b", "whole", "systhread_host", "append_mutex"),
    prim("fs.load_lines_rev_locked", r"\bFs_compat\.load_lines_rev_locked(_with)?\b", "lines", "systhread_host", "append_mutex"),
    prim("fs.load_owned_prefix", r"\bFs_compat\.load_owned_regular_file_(prefix|range)\w*", "slice", "systhread_host"),
    prim("fs.load_owned", r"\bFs_compat\.load_owned_regular_file\w*", "whole", "systhread_host"),
    prim("fs.load_file", r"\bFs_compat\.load_file(_opt|_unix)?\b", "whole", "systhread_host"),
    prim("fs.read_slice", r"\bFs_compat\.read_slice\b", "slice", "systhread_host", "append_mutex"),
    prim("fs.fold_appended_lines", r"\bFs_compat\.fold_appended_lines\b", "stream", "systhread_host", "append_mutex"),
    prim("fs.fold_jsonl_lines", r"\bFs_compat\.fold_jsonl_lines\b", "stream+parse", "systhread_host", "append_mutex"),
    prim("fs.read_dir", r"\bFs_compat\.(read_dir|list_dir)\w*", "dir", "systhread_host"),
    prim("fs.meta", r"\bFs_compat\.(file_exists|is_directory|is_regular_file|stat|lstat|file_size)\w*", "meta", "systhread_host"),
    prim("safe.read_json", r"\bSafe_ops\.read_json\w*", "whole+parse", "systhread_host"),
    prim("safe.read_file", r"\bSafe_ops\.read_file\w*", "whole", "systhread_host"),
    prim("safe.list_dir", r"\bSafe_ops\.list_dir\w*", "dir", "systhread_host"),
    prim("dj.read_recent", r"\bDated_jsonl\.(read_recent|read_range_recent)\w*", "tail", "read_pool"),
    prim("dj.load_tail", r"\bDated_jsonl\.load_tail\w*", "tail", "read_pool"),
    prim("dj.range", r"\bDated_jsonl\.(read_range|iter_range|iter_all|fold_range|fold_file|iter_json_file|iter_non_empty_lines)\w*", "range", "read_pool"),
    prim("dj.list", r"\bDated_jsonl\.list_\w*", "dir", "caller"),
    prim("yojson.from_file", r"\bYojson\.Safe\.(from_file|from_channel|seq_from_file|seq_from_channel)\b", "whole+parse", "caller"),
    prim("eio.load", r"\bEio\.Path\.(load|with_open_in|open_in)\b", "whole", "eio"),
    prim("eio.read_dir", r"\bEio\.Path\.(read_dir|with_dir_entries)\b", "dir", "eio"),
    prim("eio.meta", r"\bEio\.Path\.(stat|kind|is_file|is_directory)\b", "meta", "eio"),
    prim("stdlib.open_in", r"(?<![\w.])(Stdlib\.)?open_in(_bin|_gen)?\b", "open", "caller"),
    prim("stdlib.in_channel", r"\bIn_channel\.(with_open_bin|with_open_text|with_open_gen|open_bin|open_text|open_gen|input_all|input_line|really_input_string|input_lines|fold_lines)\b", "whole", "caller"),
    prim("stdlib.really_input", r"(?<![\w.])(Stdlib\.)?really_input(_string)?\b", "read", "caller"),
    prim("unix.openfile", r"\bUnix\.openfile\b", "open", "caller"),
    prim("unix.read", r"\bUnix\.(read|single_read|pread)\b", "read", "caller"),
    prim("unix.readdir", r"\bUnix\.(opendir|readdir)\b", "dir", "caller"),
    prim("sys.readdir", r"\bSys\.readdir\b", "dir", "caller"),
    prim("unix.meta", r"\bUnix\.(stat|lstat|fstat|LargeFile\.stat|LargeFile\.lstat|realpath)\b", "meta", "caller"),
    prim("sys.meta", r"\bSys\.(file_exists|is_directory|is_regular_file)\b", "meta", "caller"),
    prim("sqlite", r"\bSqlite3\.(prepare|exec|exec_no_headers|exec_not_null|step)\b", "db", "caller"),
)

WRAP_HINTS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("pool_io", re.compile(r"\bPool_work\.io\b|\bsubmit_io_or_inline\b")),
    ("pool_cpu", re.compile(r"\bPool_work\.cpu\b|\bsubmit_cpu_or_inline\b|\bExecutor_pool_ref\.submit")),
    ("dash_cache", re.compile(r"\bDashboard_cache\.get_or_compute\b")),
    ("systhread", re.compile(r"\bSysthread_host\.run\b|\brun_in_systhread\b")),
    ("durable_lock", re.compile(r"\bwith_durable_lock\b|\bOwner_lock\.|\blockf\b|\bwith_flock\b")),
    ("mutex", re.compile(r"\bMutex\.(protect|lock)\b|\bEio\.Mutex\.")),
    ("decode", re.compile(r"\bYojson\.Safe\.from_string\b|\bof_yojson\b|\bJsonm\b")),
)

ESCAPED_CHAR_RE = re.compile(r"'\\([\\'\"ntbr ]|x[0-9a-fA-F]{2}|o[0-7]{3}|[0-9]{3})'")
BINDING_RE = re.compile(r"^(?P<indent> {0,2})(let|and)\s+(rec\s+)?(?P<name>[a-z_][\w']*)")


def blank_comments_and_strings(source: str) -> str:
    """Replace comment and string-literal bodies with spaces, keeping newlines."""
    out: list[str] = []
    i = 0
    n = len(source)
    depth = 0
    while i < n:
        ch = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if depth > 0:
            if ch == "(" and nxt == "*":
                depth += 1
                out.append("  ")
                i += 2
            elif ch == "*" and nxt == ")":
                depth -= 1
                out.append("  ")
                i += 2
            else:
                out.append("\n" if ch == "\n" else " ")
                i += 1
            continue
        if ch == "(" and nxt == "*" and not source.startswith("(*)", i):
            depth = 1
            out.append("  ")
            i += 2
            continue
        if ch == '"':
            j = i + 1
            while j < n and source[j] != '"':
                j += 2 if source[j] == "\\" else 1
            body = source[i + 1 : j]
            out.append('"' + "".join("\n" if c == "\n" else " " for c in body) + '"')
            i = j + 1
            continue
        if ch == "{":
            m = re.match(r"\{([a-z_]*)\|", source[i:])
            if m:
                tag = m.group(1)
                end = source.find("|" + tag + "}", i + len(m.group(0)))
                if end != -1:
                    body = source[i : end + len(tag) + 2]
                    out.append("".join("\n" if c == "\n" else " " for c in body))
                    i = end + len(tag) + 2
                    continue
        if ch == "'" and nxt == "\\":
            m = ESCAPED_CHAR_RE.match(source, i)
            if m:
                out.append(" " * len(m.group(0)))
                i = m.end()
                continue
        if ch == "'" and i + 2 < n and source[i + 2] == "'" and source[i + 1] != "\\":
            out.append("' '")
            i += 3
            continue
        out.append(ch)
        i += 1
    return "".join(out)


@dataclass(frozen=True, slots=True)
class Site:
    path: str
    line: int
    group: str
    binding: str
    primitive: Primitive
    hints: tuple[str, ...]


def group_of(rel: str) -> str:
    parts = rel.split("/")
    return "/".join(parts[:2]) if len(parts) > 2 else parts[0]


MODULE_OPEN_RE = re.compile(r"^module\s+(rec\s+)?(?P<name>[A-Z][\w']*)\b.*\bstruct\s*$")


def binding_spans(lines: list[str]) -> list[tuple[int, str]]:
    """Top-level bindings, plus two-space bindings inside a column-0 `struct`."""
    spans: list[tuple[int, str]] = []
    module: str | None = None
    for index, text in enumerate(lines):
        opened = MODULE_OPEN_RE.match(text)
        if opened:
            module = opened.group("name")
            continue
        if module is not None and text.startswith("end"):
            module = None
            continue
        m = BINDING_RE.match(text)
        if not m:
            continue
        indent = len(m.group("indent"))
        if indent == 0:
            spans.append((index, m.group("name")))
        elif module is not None:
            spans.append((index, f"{module}.{m.group('name')}"))
    return spans


def scan_file(root: Path, path: Path) -> Iterator[Site]:
    rel = str(path.relative_to(root))
    clean = blank_comments_and_strings(path.read_text(encoding="utf-8", errors="replace"))
    lines = clean.split("\n")
    spans = binding_spans(lines)
    for index, text in enumerate(lines):
        taken: list[tuple[int, int]] = []
        for primitive in PRIMITIVES:
            for m in primitive.pattern.finditer(text):
                if any(a <= m.start() < b for a, b in taken):
                    continue
                taken.append((m.start(), m.end()))
                start, name = (0, "<toplevel>")
                for span_start, span_name in spans:
                    if span_start > index:
                        break
                    start, name = span_start, span_name
                end = next((s for s, _ in spans if s > start), len(lines))
                body = "\n".join(lines[start:end])
                hints = tuple(label for label, rx in WRAP_HINTS if rx.search(body))
                yield Site(rel, index + 1, group_of(rel), name, primitive, hints)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    root: Path = args.repo
    out: Path = args.out
    files = sorted(p for d in ("lib", "bin") for p in (root / d).rglob("*.ml"))
    sites = [site for f in files for site in scan_file(root, f)]
    with out.open("w", encoding="utf-8") as handle:
        handle.write("path\tline\tgroup\tbinding\tprimitive\tshape\tmech\tlock\thints\n")
        for s in sites:
            handle.write(
                f"{s.path}\t{s.line}\t{s.group}\t{s.binding}\t{s.primitive.pid}\t{s.primitive.shape}"
                f"\t{s.primitive.mech}\t{s.primitive.lock}\t{','.join(s.hints) or '-'}\n"
            )
    by_primitive = Counter(s.primitive.pid for s in sites)
    print(f"files={len(files)} sites={len(sites)}")
    for pid, count in by_primitive.most_common():
        print(f"{count:6d} {pid}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
