#!/usr/bin/env python3
"""Prevent SIGPIPE under set -o pipefail from `cmd | head` in shell scripts."""
import os
from pathlib import Path
import re
import subprocess
import unittest


REPO = Path(__file__).resolve().parents[1]
SCAN_ROOTS = ("scripts", "dashboard/scripts")
SKIP_DIRS = {".git", ".worktrees", "_build", "node_modules", "__pycache__"}

HEAD_PIPE_RE = re.compile(r'(?<!\\)\|\s*head(?:\s|$|;|\)|"|`|\')')
SOURCE_RE = re.compile(r'(?:^|[;&\s])(?:source|\.)\s+["\']?([^\s"\';&)]+\.(?:sh|bash))')


def iter_shell_scripts():
    for rel_root in SCAN_ROOTS:
        root = REPO / rel_root
        if not root.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for name in sorted(filenames):
                if name.endswith((".sh", ".bash")):
                    yield Path(dirpath) / name


def has_pipefail(body: str) -> bool:
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "pipefail" in stripped:
            return True
    return False


class ScriptsPipefailHeadTest(unittest.TestCase):
    def test_no_head_pipe_in_pipefail_or_sourced_scripts(self):
        scripts = {path.relative_to(REPO).as_posix(): path.read_text(encoding="utf-8", errors="replace")
                   for path in iter_shell_scripts()}
        self.assertGreater(len(scripts), 0, "expected shell scripts under scan roots")

        pipefail_scripts = {rel for rel, body in scripts.items() if has_pipefail(body)}
        self.assertGreater(len(pipefail_scripts), 0, "expected pipefail scripts")

        checked = set(pipefail_scripts)
        queue = list(pipefail_scripts)
        while queue:
            cur = queue.pop()
            for match in SOURCE_RE.finditer(scripts[cur]):
                sourced_name = match.group(1).split("/")[-1]
                for cand in scripts:
                    if (cand == sourced_name or cand.endswith("/" + sourced_name)) and cand not in checked:
                        checked.add(cand)
                        queue.append(cand)

        violations = []
        for rel in sorted(checked):
            for lineno, line in enumerate(scripts[rel].splitlines(), 1):
                if line.strip().startswith("#"):
                    continue
                if HEAD_PIPE_RE.search(line):
                    violations.append(f"{rel}:{lineno}: {line.rstrip()}")

        self.assertEqual(
            violations,
            [],
            "Found `| head` in pipefail or pipefail-sourced scripts (use `sed -n '1p'`, `sed -n '1,Np'`, or `awk 'NR<=limit'`):\n"
            + "\n".join(violations),
        )

    def test_sed_and_awk_drain_stdin_without_sigpipe(self):
        cases = [
            ("sed -n 1p", 'x=$(seq 1 200000 | sed -n "1p"); printf "%s" "$x"', "1"),
            ("sed -n 1,3p", 'x=$(seq 1 200000 | sed -n "1,3p"); printf "%s" "$x"', "1\n2\n3"),
            ("awk limit=3", 'x=$(seq 1 200000 | awk -v limit=3 "NR <= (limit + 0)"); printf "%s" "$x"', "1\n2\n3"),
            ("awk limit=0", 'x=$(seq 1 200000 | awk -v limit=0 "NR <= (limit + 0)"); printf "%s" "$x"', ""),
        ]
        for label, snippet, expected in cases:
            with self.subTest(label=label):
                proc = subprocess.run(
                    ["bash", "-euo", "pipefail", "-c", snippet],
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                self.assertEqual(proc.returncode, 0, f"{label} stderr: {proc.stderr}")
                self.assertEqual(proc.stdout, expected)

    def test_modified_scripts_pass_bash_syntax_check(self):
        modified_scripts = [
            "dashboard/scripts/gen-sse-types.sh",
            "scripts/build-linux-release.sh",
            "scripts/build-shim-static.sh",
            "scripts/bump-version.sh",
            "scripts/check-opam-file-regenerated.sh",
            "scripts/check-sandbox-dune-version.sh",
            "scripts/check-sandbox-ocaml-version.sh",
            "scripts/docker-playground-fd-status.sh",
            "scripts/gen-tla-index.sh",
            "scripts/harness/contract/public_tool_live_sweep.sh",
            "scripts/monitor-system-health.sh",
            "scripts/nofile-status.sh",
            "scripts/review/ci-checks.sh",
            "scripts/run-local.sh",
        ]
        for rel in modified_scripts:
            path = REPO / rel
            with self.subTest(script=rel):
                self.assertTrue(path.is_file(), f"missing {rel}")
                proc = subprocess.run(
                    ["bash", "-n", str(path)],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(proc.returncode, 0, f"bash -n {rel}: {proc.stderr}")


if __name__ == "__main__":
    unittest.main()
