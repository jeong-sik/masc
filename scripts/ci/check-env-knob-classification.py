#!/usr/bin/env python3
"""Guard new env_config typed getters with classification tags.

This is intentionally diff-scoped for #10733. Existing env knobs remain in the
generated catalog/backfill lane; new `get_* ~default` call sites in
`lib/config/env_config_*.ml` must carry nearby `@category` and `@ops_class`
metadata so the catalog does not keep growing as an unclassified pile.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


GETTER_RE = re.compile(
    r"\b(?:Env_config_core\.)?get_"
    r"(?:int|int_nonneg|float|float_nonneg|float_in_range|ratio|string|bool)\b"
)
CONFIG_PATH_RE = re.compile(r"^lib/config/env_config_[^/]+\.ml$")
CATEGORY_RE = re.compile(r"@category\s+([A-Za-z_]+)")
OPS_CLASS_RE = re.compile(r"@ops_class\s+([A-Za-z_]+)")

VALID_CATEGORIES = {
    "Timeouts",
    "Concurrency",
    "Thresholds",
    "Policies",
    "Identity",
    "Telemetry",
    "Storage",
    "Security",
    "Sandbox",
    "Dashboard",
    "Inference",
    "Runtime",
}
VALID_OPS_CLASSES = {"operator", "algorithm"}


@dataclass(frozen=True)
class AddedGetter:
    path: str
    line_no: int
    text: str


def run_git_diff(base: str, head: str) -> str:
    result = subprocess.run(
        [
            "git",
            "diff",
            "--unified=0",
            f"{base}...{head}",
            "--",
            "lib/config",
        ],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode not in (0, 1):
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return result.stdout


def added_getters_from_diff(diff_text: str) -> list[AddedGetter]:
    current_path: str | None = None
    new_line_no: int | None = None
    added: list[AddedGetter] = []

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
            if CONFIG_PATH_RE.match(current_path) and is_getter_default_line(text):
                added.append(AddedGetter(current_path, new_line_no, text.strip()))
            new_line_no += 1
        elif raw.startswith("-") and not raw.startswith("---"):
            continue
        else:
            new_line_no += 1

    return added


def is_getter_default_line(text: str) -> bool:
    stripped = text.strip()
    if stripped.startswith("let get_") or stripped.startswith("and get_"):
        return False
    return bool(GETTER_RE.search(stripped) and "~default" in stripped)


def read_lines(path: str) -> list[str]:
    try:
        return Path(path).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return []


def nearby_tag_block(lines: list[str], line_no: int, lookback: int = 12) -> tuple[str | None, str | None]:
    idx = max(0, line_no - 1)
    start = max(0, idx - lookback)
    nearby = "\n".join(lines[start : idx + 1])
    category_match = CATEGORY_RE.search(nearby)
    ops_match = OPS_CLASS_RE.search(nearby)
    category = category_match.group(1) if category_match else None
    ops_class = ops_match.group(1) if ops_match else None
    return category, ops_class


def validate_getter(getter: AddedGetter) -> str | None:
    lines = read_lines(getter.path)
    category, ops_class = nearby_tag_block(lines, getter.line_no)
    problems: list[str] = []
    if category is None:
        problems.append("missing @category")
    elif category not in VALID_CATEGORIES:
        problems.append(
            f"invalid @category {category!r}; expected one of {', '.join(sorted(VALID_CATEGORIES))}"
        )
    if ops_class is None:
        problems.append("missing @ops_class")
    elif ops_class not in VALID_OPS_CLASSES:
        problems.append(
            f"invalid @ops_class {ops_class!r}; expected operator or algorithm"
        )
    if not problems:
        return None
    return f"{getter.path}:{getter.line_no}: {', '.join(problems)} near `{getter.text}`"


def check(base: str, head: str) -> int:
    diff_text = run_git_diff(base, head)
    added = added_getters_from_diff(diff_text)
    failures = [failure for getter in added if (failure := validate_getter(getter))]
    if failures:
        print("Env knob classification guard failed.")
        print("New typed env getters in lib/config/env_config_*.ml need nearby:")
        print("  @category Timeouts|Concurrency|Thresholds|Policies|Identity|Telemetry|Storage|Security|Sandbox|Dashboard|Inference|Runtime")
        print("  @ops_class operator|algorithm")
        print()
        for failure in failures:
            print(failure)
        return 1
    print(f"Env knob classification guard passed ({len(added)} new typed getter line(s)).")
    return 0


def self_test() -> int:
    diff = """diff --git a/lib/config/env_config_runtime.ml b/lib/config/env_config_runtime.ml
--- a/lib/config/env_config_runtime.ml
+++ b/lib/config/env_config_runtime.ml
@@ -10,0 +11,2 @@
+let foo =
+  get_int ~default:1 "MASC_FOO"
diff --git a/lib/config/env_config_core.ml b/lib/config/env_config_core.ml
--- a/lib/config/env_config_core.ml
+++ b/lib/config/env_config_core.ml
@@ -1,0 +2,1 @@
+let get_int ~default name = default
"""
    added = added_getters_from_diff(diff)
    assert added == [
        AddedGetter("lib/config/env_config_runtime.ml", 12, 'get_int ~default:1 "MASC_FOO"')
    ], added

    good_lines = [
        "(** @category Timeouts",
        "    @ops_class operator *)",
        "let foo =",
        '  get_int ~default:1 "MASC_FOO"',
    ]
    assert nearby_tag_block(good_lines, 4) == ("Timeouts", "operator")

    bad_getter = AddedGetter("missing.ml", 1, 'get_float ~default:1.0 "MASC_BAD"')
    assert "missing @category" in (validate_getter(bad_getter) or "")
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
