#!/usr/bin/env python3
"""Ensure lib/ and bin/ never re-introduce two-stat file_exists + is_directory."""
import os
from pathlib import Path
import re
import unittest


REPO = Path(__file__).resolve().parents[1]
SCAN_ROOTS = ("lib", "bin")

_MOD = r"(?:(?:Stdlib\.)?Sys|Fs_compat)"
# Bounded span between `file_exists <arg>` and `&&` / `||` that cannot cross
# `;`, another boolean op, or an OCaml binding/clause keyword.
_CLAUSE_BOUNDARY_RE = re.compile(
    r"\b(?:let|in|then|else|match|with|val|type|module|fun|function|try)\b"
)

DOUBLE_STAT_PATTERNS = (
    re.compile(
        rf"(?P<lhs>{_MOD}\.file_exists\b)(?P<between>[^;&|]{{0,200}}?)&&\s*"
        rf"(?:\(\s*)?(?:not\s*\(\s*)?(?P<rhs>{_MOD}\.is_directory\b)",
        re.S,
    ),
    re.compile(
        rf"(?P<lhs>{_MOD}\.file_exists\b)(?P<between>[^;&|]{{0,200}}?)&&\s*"
        rf"\(\s*match\s+(?P<rhs>{_MOD}\.is_directory\b)",
        re.S,
    ),
    re.compile(
        rf"not\s*\(\s*(?P<lhs>{_MOD}\.file_exists\b)(?P<between>[^;&|]{{0,200}}?)\|\|\s*"
        rf"(?:\(\s*)?(?:not\s*\(\s*)?(?P<rhs>{_MOD}\.is_directory\b)",
        re.S,
    ),
)
EXISTING_ROOT_DOUBLE_STAT_RE = re.compile(
    r"(?:Stdlib\.)?Sys\.file_exists\s+config_root\b"
)


def strip_ocaml_comments(text: str) -> str:
    """Replace nested OCaml (* ... *) comments with spaces, preserving newlines."""
    out: list[str] = []
    i = 0
    n = len(text)
    depth = 0
    in_string = False
    while i < n:
        ch = text[i]
        if depth > 0:
            if ch == "(" and i + 1 < n and text[i + 1] == "*":
                depth += 1
                out.append("  ")
                i += 2
            elif ch == "*" and i + 1 < n and text[i + 1] == ")":
                depth -= 1
                out.append("  ")
                i += 2
            elif ch == "\n":
                out.append("\n")
                i += 1
            else:
                out.append(" ")
                i += 1
        elif in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
            else:
                if ch == '"':
                    in_string = False
                i += 1
        else:
            if ch == "(" and i + 1 < n and text[i + 1] == "*":
                depth = 1
                out.append("  ")
                i += 2
            elif ch == '"':
                in_string = True
                out.append(ch)
                i += 1
            elif ch == "'" and i + 3 < n and text[i + 1] == "\\" and text[i + 3] == "'":
                out.append(text[i : i + 4])
                i += 4
            elif ch == "'" and i + 2 < n and text[i + 1] not in ("'", "\\") and text[i + 2] == "'":
                out.append(text[i : i + 3])
                i += 3
            else:
                out.append(ch)
                i += 1
    return "".join(out)


def _extract_ocaml_arg(text: str, pos: int) -> str | None:
    """Extract the first OCaml argument expression starting at or after pos."""
    n = len(text)
    while pos < n and text[pos].isspace():
        pos += 1
    if pos >= n:
        return None
    if text[pos] == "(":
        depth = 0
        start = pos
        while pos < n:
            ch = text[pos]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return text[start : pos + 1]
            pos += 1
        return None
    start = pos
    while pos < n and (text[pos].isalnum() or text[pos] in "_.'"):
        pos += 1
    return text[start:pos] if pos > start else None


def _normalize_arg(arg: str) -> str:
    s = " ".join(arg.split())
    while len(s) >= 2 and s[0] == "(" and s[-1] == ")":
        depth = 0
        balanced = True
        for idx, ch in enumerate(s):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0 and idx < len(s) - 1:
                    balanced = False
                    break
        if balanced and depth == 0:
            s = s[1:-1].strip()
        else:
            break
    return s


def find_double_stat_violations(rel: str, text: str) -> list[str]:
    if "file_exists" not in text:
        return []
    stripped = strip_ocaml_comments(text)
    found: list[tuple[int, str]] = []
    seen_lines: set[int] = set()
    for pat in DOUBLE_STAT_PATTERNS:
        for match in pat.finditer(stripped):
            between = match.group("between")
            if _CLAUSE_BOUNDARY_RE.search(between):
                continue
            arg1 = _extract_ocaml_arg(stripped, match.end("lhs"))
            arg2 = _extract_ocaml_arg(stripped, match.end("rhs"))
            if arg1 is not None and arg2 is not None:
                if _normalize_arg(arg1) != _normalize_arg(arg2):
                    continue
            lineno = stripped.count("\n", 0, match.start()) + 1
            if lineno in seen_lines:
                continue
            seen_lines.add(lineno)
            snippet = " ".join(match.group(0).split())
            found.append((lineno, f"{rel}:{lineno}: {snippet}"))
    if rel == "lib/server/server_runtime_config_root_bootstrap.ml":
        for lineno, line in enumerate(stripped.splitlines(), 1):
            if lineno not in seen_lines and EXISTING_ROOT_DOUBLE_STAT_RE.search(line):
                seen_lines.add(lineno)
                found.append((lineno, f"{rel}:{lineno}: {line.strip()}"))
    found.sort()
    return [entry for _, entry in found]


def iter_ocaml_sources():
    for rel_root in SCAN_ROOTS:
        root = REPO / rel_root
        if not root.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            for name in sorted(filenames):
                if name.endswith((".ml", ".mli")):
                    yield Path(dirpath) / name


class NoDoubleStatDirCheckTest(unittest.TestCase):
    def test_detector_catches_all_two_stat_shapes_and_allows_single_stat(self):
        bad_samples = (
            "if Sys.file_exists p && Sys.is_directory p then ()",
            "if Stdlib.Sys.file_exists p && Stdlib.Sys.is_directory p then ()",
            "if Sys.file_exists p && Stdlib.Sys.is_directory p then ()",
            "if Fs_compat.file_exists p && Sys.is_directory p then ()",
            "let ok =\n  Sys.file_exists (masc_dir config) &&\n  Sys.is_directory (masc_dir config)\nin ok",
            "if Sys.file_exists (Filename.concat a (b c)) && Sys.is_directory (Filename.concat a (b c)) then ()",
            "if Sys.file_exists dst && not (Sys.is_directory dst) then ()",
            "if Sys.file_exists dst && not (Stdlib.Sys.is_directory dst) then ()",
            "if Sys.file_exists path && (not (Sys.is_directory path)) then ()",
            "if not (Sys.file_exists p) || Sys.is_directory p then ()",
            "if not (Stdlib.Sys.file_exists p) || Stdlib.Sys.is_directory p then ()",
            "let x = Sys.file_exists dir && (match Sys.is_directory dir with | d -> not d | exception _ -> false)",
        )
        for sample in bad_samples:
            with self.subTest(bad=sample):
                self.assertTrue(
                    find_double_stat_violations("lib/sample.ml", sample),
                    f"expected detector to flag: {sample}",
                )

        good_samples = (
            "if Fs_compat.is_directory p then ()",
            "if Fs_compat.is_file p then ()",
            "if Env_config_core.existing_dir p && Env_config_core.existing_file q then ()",
            "Fs_compat.is_directory (masc_dir config) && Fs_compat.file_exists (state_path config)",
            "if Sys.file_exists (state_path cfg) && Fs_compat.is_directory (masc_dir cfg) then ()",
            "let f p = Sys.file_exists p\nlet g q = flag && Fs_compat.is_directory q\n",
            "(* Avoids Sys.file_exists p && Sys.is_directory p (* nested *) *)\nlet ok = true\n",
            "let quotes = ['\\'';'\"']\n(* Sys.file_exists p && Sys.is_directory p *)\nlet ok = true\n",
            "let a = Sys.file_exists p in (); let b = Sys.is_directory q in b",
        )
        for sample in good_samples:
            with self.subTest(good=sample):
                self.assertEqual(
                    find_double_stat_violations("lib/sample.ml", sample),
                    [],
                    f"expected detector to allow: {sample}",
                )

    def test_no_double_stat_directory_checks_in_lib_or_bin(self):
        violations = []
        sources = list(iter_ocaml_sources())
        self.assertGreater(len(sources), 0, "expected OCaml files under lib/ and bin/")
        for path in sources:
            rel = path.relative_to(REPO).as_posix()
            text = path.read_text(encoding="utf-8", errors="replace")
            violations.extend(find_double_stat_violations(rel, text))

        self.assertEqual(
            violations,
            [],
            "Found two-stat file_exists + is_directory checks "
            "(use Fs_compat.is_directory, Fs_compat.is_file, or Env_config_core.existing_dir/existing_file):\n"
            + "\n".join(violations),
        )


if __name__ == "__main__":
    unittest.main()
