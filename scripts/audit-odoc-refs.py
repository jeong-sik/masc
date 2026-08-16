#!/usr/bin/env python3
"""Fail when an `.mli` doc names a symbol the tree does not define.

An odoc reference `{!foo}` is not checked by the compiler. A rename or a
deletion leaves it syntactically valid and silently wrong, and the doc keeps
asserting something about code that is gone. Nine such references were found in
one sweep (#27485):

    mcp_prompt_surface.mli   justified a concrete record with
                             "Mcp_sdk_adapter_masc.sdk_prompt_of_local reads
                             every field" -- that module has no prompt function
    server_mcp_transport_ws  named read_inbound_message_frame three times as the
                             reason ws_session is exposed; absent, and the
                             module it credited uses neither of the two symbols
    operator_judgment.mli    "Two read paths" naming a latest_active_json that
                             does not exist
    tool_schemas_misc.mli    an enum derived from dashboard_scope_enum_strings,
                             which does not exist
    three .mli files         {!Foo.ml}, which reads as a value `ml` inside Foo

What this checks is narrow on purpose: a lowercase final component, since a
capitalised one is a module and module resolution has its own rules. The
result is a name that either resolves to a value/type in this tree or does not.

The known-symbol set is deliberately generous -- every `let`/`val`/`type`/
`module`/`exception` binding, record fields, variant arms, ppx-derived
`*_to_yojson` / `show_*` / `pp_*`, and test executable names -- because a false
positive costs a person a lookup while a false negative is the drift this
exists to catch. External modules are skipped by prefix for the same reason.

Usage:
    scripts/audit-odoc-refs.py            # report, exit 1 on any hit
    scripts/audit-odoc-refs.py --list     # report, always exit 0
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Module prefixes that live outside lib/. A reference through one of these is
# not checkable here and is not evidence of drift.
EXTERNAL_MODULE_PREFIXES = frozenset(
    {
        "Agent_core",
        "Alcotest",
        "Array",
        "Astring",
        "Atomic",
        "Bool",
        "Buffer",
        "Bytes",
        "Char",
        "Cmdliner",
        "Cohttp",
        "Digestif",
        "Domain",
        "Eio",
        "Filename",
        "Float",
        "Format",
        "Fun",
        "H2",
        "Hashtbl",
        "Httpun",
        "Int",
        "Lazy",
        "List",
        "Llm_provider",
        "Logs",
        "Map",
        "Mcp_protocol",
        "Mirage_crypto",
        "Mutex",
        "Option",
        "Printf",
        "Ptime",
        "Queue",
        "Random",
        "Re",
        "Result",
        "Scanf",
        "Seq",
        "Set",
        "Stack",
        "Stdlib",
        "Str",
        "String",
        "Sys",
        "Unix",
        "Uri",
        "Yojson",
    }
)

BINDING_RE = re.compile(
    r"^\s*(?:let|val|type|and|module|exception|external)\s+(?:rec\s+)?"
    r"([A-Za-z_][A-Za-z0-9_']*)",
    re.M,
)
RECORD_FIELD_RE = re.compile(r"^\s*([a-z_][A-Za-z0-9_']*)\s*:", re.M)
VARIANT_ARM_RE = re.compile(r"^\s*\|\s*([A-Za-z_][A-Za-z0-9_']*)", re.M)
TYPE_NAME_RE = re.compile(r"^\s*type\s+([a-z_][A-Za-z0-9_']*)", re.M)
DOC_RE = re.compile(r"\(\*\*(.*?)\*\)", re.S)
ODOC_REF_RE = re.compile(r"\{!([A-Za-z_][A-Za-z0-9_'.]*)\}")

# `[foo]` is odoc code formatting, not a reference, so odoc never resolves it
# and neither does the sweep above. One shape of it still makes a checkable
# claim: "these helpers stay private" asserts the listed names exist AND are
# unexported, which is a statement about the paired .ml and nothing else. When
# such a name is absent the note describes a private layer that was never
# there -- the wrong thing to hand a reader who cannot see the .ml. #26634
# found eight; two outlived the {!...} sweep by being written in brackets.
#
# Scoped three ways, because brackets are used for far more than symbols:
#   - only the line carrying the private-note phrase, not the whole comment,
#     so neighbouring prose about tools and modules is out
#   - resolved against the paired .ml alone, since "private here" is a claim
#     about this module and a tree-wide symbol set would answer a different
#     question
#   - leading-underscore names skipped: `[_eio]`, `[_list]` are name fragments
#     the prose is spelling out, not bindings
PRIVATE_NOTE_RE = re.compile(
    r"(?:Internal:|(?:stay|remain)s? private|Selective \.mli)", re.I)
BRACKET_NAME_RE = re.compile(r"\[([a-z][a-z0-9_']*)\]")

DERIVED_SUFFIXES = ("_to_yojson", "_of_yojson")
DERIVED_PREFIXES = ("show_", "pp_", "equal_", "compare_")


def source_files() -> list[Path]:
    roots = [REPO_ROOT / "lib", REPO_ROOT / "test"]
    files: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if path.suffix in (".ml", ".mli") and "_build" not in path.parts:
                files.append(path)
    return files


def known_symbols(files: list[Path]) -> set[str]:
    known: set[str] = set()
    for path in files:
        try:
            text = path.read_text(errors="ignore")
        except OSError:
            continue
        known |= set(BINDING_RE.findall(text))
        known |= set(RECORD_FIELD_RE.findall(text))
        known |= set(VARIANT_ARM_RE.findall(text))
        for type_name in TYPE_NAME_RE.findall(text):
            known |= {type_name + suffix for suffix in DERIVED_SUFFIXES}
            known |= {prefix + type_name for prefix in DERIVED_PREFIXES}
    # Test executables are referenced by name from library docs.
    test_dir = REPO_ROOT / "test"
    if test_dir.exists():
        known |= {path.stem for path in test_dir.glob("*.ml")}
    return known


def absent_references(known: set[str]) -> list[tuple[Path, str]]:
    hits: list[tuple[Path, str]] = []
    lib = REPO_ROOT / "lib"
    for path in sorted(lib.rglob("*.mli")):
        if "_build" in path.parts:
            continue
        try:
            text = path.read_text(errors="ignore")
        except OSError:
            continue
        for doc in DOC_RE.findall(text):
            for ref in ODOC_REF_RE.findall(doc):
                parts = ref.split(".")
                if parts[0] in EXTERNAL_MODULE_PREFIXES:
                    continue
                last = parts[-1]
                if not last or not last[0].islower():
                    continue
                if last not in known:
                    hits.append((path, ref))
        ml_path = path.with_suffix(".ml")
        if ml_path.exists():
            try:
                ml_text = ml_path.read_text(errors="ignore")
            except OSError:
                ml_text = ""
            for line in text.splitlines():
                if not PRIVATE_NOTE_RE.search(line):
                    continue
                for name in BRACKET_NAME_RE.findall(line):
                    if not re.search(r"\b%s\b" % re.escape(name), ml_text):
                        hits.append((path, "[%s]" % name))
    return hits


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--list",
        action="store_true",
        help="Report and exit 0, for inspecting the current state.",
    )
    args = parser.parse_args()

    files = source_files()
    hits = absent_references(known_symbols(files))

    if not hits:
        print(f"[odoc-refs] OK - every {{!...}} and every private-note [name] in lib/**/*.mli resolves ({len(files)} files scanned)")
        return 0

    print(f"[odoc-refs] {len(hits)} reference(s) name a symbol this tree does not define:\n")
    for path, ref in hits:
        rendered = ref if ref.startswith("[") else "{!%s}" % ref
        print(f"  {path.relative_to(REPO_ROOT)}: {rendered}")
    print(
        "\nEither the symbol was renamed or removed and the doc did not follow,"
        "\nor it lives outside lib/ and its module prefix belongs in"
        "\nEXTERNAL_MODULE_PREFIXES in this script."
    )
    return 0 if args.list else 1


if __name__ == "__main__":
    sys.exit(main())
