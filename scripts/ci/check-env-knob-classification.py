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
OCAML_TOKEN_RE = re.compile(
    r"(?P<quoted_string>\{(?P<delimiter>[a-z0-9_']*)\|.*?\|(?P=delimiter)\})"
    r'|(?P<string>"(?:\\.|[^"\\])*")'
    r"|(?P<comment_open>\(\*)"
    r"|(?P<comment_close>\*\))"
    r"|(?P<label>~[a-z_][A-Za-z0-9_']*)"
    r"|(?P<identifier>[A-Za-z_][A-Za-z0-9_']*(?:\.[A-Za-z_][A-Za-z0-9_']*)*)"
    r"|(?P<symbol>\S)",
    re.DOTALL,
)

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


@dataclass(frozen=True)
class AddedLine:
    line_no: int
    text: str


@dataclass(frozen=True)
class OcamlToken:
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


def ocaml_tokens(lines: list[AddedLine]) -> list[OcamlToken]:
    """Tokenize the OCaml forms needed to identify typed getter applications.

    The guard only needs identifiers and labels, but it must not treat text in
    nested comments or string literals as code. Keeping line numbers on tokens
    lets the diff check report the getter's actual source line.
    """

    source = "\n".join(line.text for line in lines)
    tokens: list[OcamlToken] = []
    comment_depth = 0
    first_line_no = lines[0].line_no if lines else 0
    for match in OCAML_TOKEN_RE.finditer(source):
        if match.group("comment_open") is not None:
            comment_depth += 1
            continue
        if match.group("comment_close") is not None:
            comment_depth = max(0, comment_depth - 1)
            continue
        if comment_depth > 0:
            continue
        if (
            match.group("string") is not None
            or match.group("quoted_string") is not None
        ):
            continue
        token = match.group("label", "identifier", "symbol")
        text = next(value for value in token if value is not None)
        line_no = first_line_no + source.count("\n", 0, match.start())
        tokens.append(OcamlToken(line_no, text))
    return tokens


def is_getter_binding(tokens: list[OcamlToken], getter_idx: int) -> bool:
    if getter_idx == 0:
        return False
    previous = tokens[getter_idx - 1].text
    if previous in {"let", "and"}:
        return True
    return (
        getter_idx >= 2 and previous == "rec" and tokens[getter_idx - 2].text == "let"
    )


def getters_from_added_chunk(path: str, lines: list[AddedLine]) -> list[AddedGetter]:
    tokens = ocaml_tokens(lines)
    source_lines = {line.line_no: line.text.strip() for line in lines}
    getters: list[AddedGetter] = []
    for idx, token in enumerate(tokens[:-1]):
        if (
            GETTER_RE.fullmatch(token.text)
            and tokens[idx + 1].text == "~default"
            and not is_getter_binding(tokens, idx)
        ):
            getters.append(
                AddedGetter(path, token.line_no, source_lines[token.line_no])
            )
    return getters


def added_getters_from_diff(diff_text: str) -> list[AddedGetter]:
    current_path: str | None = None
    new_line_no: int | None = None
    added: list[AddedGetter] = []
    chunk: list[AddedLine] = []

    def flush_chunk() -> None:
        nonlocal chunk
        if current_path is not None and CONFIG_PATH_RE.match(current_path):
            added.extend(getters_from_added_chunk(current_path, chunk))
        chunk = []

    for raw in diff_text.splitlines():
        if raw.startswith("+++ b/"):
            flush_chunk()
            current_path = raw[len("+++ b/") :]
            new_line_no = None
            continue
        if raw.startswith("diff --git "):
            flush_chunk()
            current_path = None
            new_line_no = None
            continue
        if raw.startswith("@@ "):
            flush_chunk()
            match = re.search(r"\+(\d+)(?:,(\d+))?", raw)
            new_line_no = int(match.group(1)) if match else None
            continue
        if current_path is None or new_line_no is None:
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            text = raw[1:]
            chunk.append(AddedLine(new_line_no, text))
            new_line_no += 1
        elif raw.startswith("-") and not raw.startswith("---"):
            flush_chunk()
            continue
        else:
            flush_chunk()
            new_line_no += 1

    flush_chunk()
    return added


def read_lines(path: str) -> list[str]:
    try:
        return Path(path).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return []


def nearby_tag_block(
    lines: list[str], line_no: int, lookback: int = 12
) -> tuple[str | None, str | None]:
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
        print(
            "  @category Timeouts|Concurrency|Thresholds|Policies|Identity|Telemetry|Storage|Security|Sandbox|Dashboard|Inference|Runtime"
        )
        print("  @ops_class operator|algorithm")
        print()
        for failure in failures:
            print(failure)
        return 1
    print(
        f"Env knob classification guard passed ({len(added)} new typed getter call(s))."
    )
    return 0


def self_test() -> int:
    diff = """diff --git a/lib/config/env_config_runtime.ml b/lib/config/env_config_runtime.ml
--- a/lib/config/env_config_runtime.ml
+++ b/lib/config/env_config_runtime.ml
@@ -10,0 +11,7 @@
+let foo =
+  get_int ~default:1 "MASC_FOO"
+let bar =
+  Env_config_core.get_float_nonneg
+    ~default:1.0
+    "MASC_BAR"
+;;
diff --git a/lib/config/env_config_core.ml b/lib/config/env_config_core.ml
--- a/lib/config/env_config_core.ml
+++ b/lib/config/env_config_core.ml
@@ -1,0 +2,4 @@
+let get_int
+  ~default
+  name =
+  default
"""
    added = added_getters_from_diff(diff)
    assert added == [
        AddedGetter(
            "lib/config/env_config_runtime.ml", 12, 'get_int ~default:1 "MASC_FOO"'
        ),
        AddedGetter(
            "lib/config/env_config_runtime.ml", 14, "Env_config_core.get_float_nonneg"
        ),
    ], added

    commented = [
        AddedLine(1, "(* get_int"),
        AddedLine(2, '   ~default:1 "MASC_COMMENT" *)'),
        AddedLine(3, 'let text = "get_float ~default:1.0 MASC_STRING"'),
        AddedLine(4, "let quoted = {| get_bool"),
        AddedLine(5, '~default:false "MASC_QUOTED" |}'),
    ]
    assert getters_from_added_chunk("lib/config/env_config_runtime.ml", commented) == []

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
