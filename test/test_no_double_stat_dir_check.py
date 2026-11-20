#!/usr/bin/env python3
"""Ensure lib/ and bin/ never re-introduce two-stat file_exists && is_directory."""
import os
from pathlib import Path
import re
import unittest


REPO = Path(__file__).resolve().parents[1]
SCAN_ROOTS = ("lib", "bin")
DOUBLE_STAT_RE = re.compile(
    r"(?:Sys|Fs_compat)\.file_exists\b[^&\n]+&&\s*Sys\.is_directory\b"
)
EXISTING_ROOT_DOUBLE_STAT_RE = re.compile(
    r"Sys\.file_exists\s+config_root\b"
)


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
    def test_no_double_stat_directory_checks_in_lib_or_bin(self):
        violations = []
        sources = list(iter_ocaml_sources())
        self.assertGreater(len(sources), 0, "expected OCaml files under lib/ and bin/")
        for path in sources:
            rel = path.relative_to(REPO).as_posix()
            text = path.read_text(encoding="utf-8", errors="replace")
            for lineno, line in enumerate(text.splitlines(), 1):
                if DOUBLE_STAT_RE.search(line):
                    violations.append(f"{rel}:{lineno}: {line.strip()}")
                if rel == "lib/server/server_runtime_config_root_bootstrap.ml" and EXISTING_ROOT_DOUBLE_STAT_RE.search(line):
                    violations.append(f"{rel}:{lineno}: {line.strip()}")

        self.assertEqual(
            violations,
            [],
            "Found two-stat file_exists && Sys.is_directory checks (use Fs_compat.is_directory or Env_config_core.existing_dir):\n"
            + "\n".join(violations),
        )


if __name__ == "__main__":
    unittest.main()
