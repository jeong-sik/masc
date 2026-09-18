#!/usr/bin/env python3
"""Self-test for referencing_suites.py (RFC-0428).

The gate runs what this names and nothing else it would have missed, so a
suite it fails to name is a pull request merged without its test, and a
comment or string it mistakes for code is a suite run for nothing. Each shape
is a file in a throwaway git repository rather than a claim in prose.

Run directly: `python3 scripts/ci/test_referencing_suites.py`
Exits 0 on success, 1 when any expectation fails.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "ci"))

from referencing_suites import file_suites, module_suites, tracked_files  # noqa: E402

FILES = {
    "lib/widgets/widget.ml": "let make () = ()\n",
    "lib/widgets/widget.mli": "val make : unit -> unit\n",
    "lib/dune": "(library (name masc))\n",
    "test/dune": "(test (name test_qualified))\n",
    "scripts/install-thing.py": "print('install')\n",
    "scripts/masc-install-thing.py": "print('other')\n",
    "config/shared.toml": "a = 1\n",
    "config/extra/shared.toml": "a = 2\n",
    "test/test_qualified.ml": "let () = Widget.make ()\n",
    "test/test_wrapped.ml": "let () = Masc.Widget.make ()\n",
    "test/test_opened.ml": "open Masc.Widget\nlet () = make ()\n",
    "test/test_local_open.ml": "let () = let open Widget in make ()\n",
    "test/test_aliased.ml": "module W = Masc.Widget\nlet () = W.make ()\n",
    "test/test_first_class.ml": "let m = (module Widget : S)\n",
    "test/test_comment_only.ml": "(* Widget.make is exercised elsewhere *)\nlet () = ()\n",
    "test/test_nested_comment.ml": "(* outer (* inner *) Widget.make *)\nlet () = ()\n",
    "test/test_string_only.ml": "let name = \"Widget.make\"\n",
    "test/test_quoted_string_only.ml": "let doc = {|Widget.make|}\nlet tagged = {id|Widget.make|id}\n",
    "test/test_comment_opener_in_string.ml": "let s = \"(*\"\nlet () = Widget.make ()\n",
    "test/test_char_quote.ml": "let q = '\"'\nlet () = Widget.make ()\n",
    "test/test_string_closer_in_comment.ml": "(* \"*)\" Widget.make *)\nlet () = ()\n",
    "test/test_prefix_name.ml": "let () = Widget_extra.make ()\n",
    "test/sub/test_nested_dir.ml": "let () = Widget.make ()\n",
    "packages/agent_core/test/test_package_root.ml": "let () = Widget.make ()\n",
    "test/test_helper_py.py": "SCRIPT = 'scripts/install-thing.py'\n",
    "test/test_names_script.ml": "let script = \"install-thing.py\"\n",
    "test/test_names_longer_script.ml": "let script = \"masc-install-thing.py\"\n",
    "test/test_names_shared.ml": "let config = \"shared.toml\"\nlet dune = \"dune\"\n",
    "test/test_names_suite_file.ml": "let other = \"test_qualified.ml\"\n",
    "test/test_names_new_file.ml": "let added = \"brand-new.toml\"\n",
    "test/not_a_suite.ml": "let () = Widget.make ()\n",
}

failures: list[str] = []


def expect(label: str, got: set[str], want: set[str]) -> None:
    if got == want:
        print(f"ok   {label}")
    else:
        print(f"FAIL {label}")
        print(f"     missing: {sorted(want - got)}")
        print(f"     extra:   {sorted(got - want)}")
        failures.append(label)


def main() -> int:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        for path, text in FILES.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(text)
        subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
        subprocess.run(["git", "add", "--all"], cwd=root, check=True)
        tracked = tracked_files(root)

        callers = {
            "test/test_qualified.ml",
            "test/test_wrapped.ml",
            "test/test_opened.ml",
            "test/test_local_open.ml",
            "test/test_aliased.ml",
            "test/test_first_class.ml",
            "test/test_comment_opener_in_string.ml",
            "test/test_char_quote.ml",
            "test/sub/test_nested_dir.ml",
            "packages/agent_core/test/test_package_root.ml",
        }
        expect("an implementation edit names every suite that calls the module",
               module_suites(root, tracked, ["lib/widgets/widget.ml"]), callers)
        expect("an interface edit is an edit to the same module",
               module_suites(root, tracked, ["lib/widgets/widget.mli"]), callers)
        expect("a source outside bin, lib and packages names no caller",
               module_suites(root, tracked, ["scripts/widget.ml"]), set())
        expect("a changed script does not reach the module rule",
               module_suites(root, tracked, ["scripts/install-thing.py"]), set())

        expect("a unique file name reaches .ml and runnable-or-not .py suites",
               file_suites(root, tracked, ["scripts/install-thing.py"]),
               {"test/test_helper_py.py", "test/test_names_script.ml"})
        expect("a name inside a longer name is not that file",
               file_suites(root, tracked, ["scripts/masc-install-thing.py"]),
               {"test/test_names_longer_script.ml"})
        expect("a shared name says nothing about which file a suite means",
               file_suites(root, tracked, ["config/shared.toml", "lib/dune"]), set())
        expect("an edited test is not a name to look for",
               file_suites(root, tracked, ["test/test_qualified.ml"]), set())
        expect("OCaml sources are left to the module rule",
               file_suites(root, tracked, ["lib/widgets/widget.ml"]), set())
        expect("a name no tracked file has yet is still looked for",
               file_suites(root, tracked, ["config/brand-new.toml"]),
               {"test/test_names_new_file.ml"})

    if failures:
        print(f"referencing_suites self-test: {len(failures)} case(s) failed")
        return 1
    print("referencing_suites self-test: all cases pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
