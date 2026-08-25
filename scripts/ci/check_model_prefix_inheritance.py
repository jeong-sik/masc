#!/usr/bin/env python3
"""Every runtime model resolves to its own capability row, or to none.

`Model_catalog.lookup` is a longest-prefix match, so a model id that no row
names exactly still lands on a shorter row and inherits its capabilities. The
subscription models already guard this by asserting the resolved id_prefix
(packages/agent_core/test/test_model_catalog_default.ml). The overlay rows
masc declares had no equivalent.

Inheriting is not automatically wrong — it is how a new tag picks up its
family. What is wrong is inheriting silently: a model that lands on a
shorter row keeps only three of its runtime.toml capability fields
(runtime_adapter.ml:317-360), the rest come from the row it landed on. A
model with no match at all keeps all of them. So the quiet case is the one
that loses its own declaration.

This lists every inheritance so it is a decision rather than a discovery.
Add the pair to ACCEPTED_INHERITANCE with why, or give the model its own row.
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
OVERLAY = REPO / "config" / "agent-core-models-overlay.toml"
RUNTIME = REPO / "config" / "runtime.toml"

# model id -> the shorter row it lands on, with the reason it is safe.
ACCEPTED_INHERITANCE = {
    "deepseek-v4-flash:0731": (
        "deepseek-v4-flash",
        "same declared thinking_control_format and context window; the tag is "
        "a pinned build of the same model",
    ),
}


def declared_prefixes() -> set[str]:
    if not OVERLAY.exists():
        sys.exit(f"FAIL: {OVERLAY.relative_to(REPO)} is missing")
    text = OVERLAY.read_text(encoding="utf-8", errors="replace")
    return {m.lower() for m in re.findall(r'id_prefix\s*=\s*"([^"]+)"', text)}


def runtime_models() -> set[str]:
    if not RUNTIME.exists():
        sys.exit(f"FAIL: {RUNTIME.relative_to(REPO)} is missing")
    text = RUNTIME.read_text(encoding="utf-8", errors="replace")
    return {m.lower() for m in re.findall(r'api-name\s*=\s*"([^"]+)"', text)}


def main() -> int:
    print("=== model prefix inheritance ===")
    prefixes = declared_prefixes()
    models = runtime_models()
    if not prefixes or not models:
        print("FAIL: no rows found; the scan lost its subject")
        return 1

    undeclared: list[tuple[str, str]] = []
    for model in sorted(models):
        landed = sorted(
            (p for p in prefixes if model.startswith(p)), key=len, reverse=True
        )
        if not landed:
            continue
        row = landed[0]
        if row == model:
            continue
        accepted = ACCEPTED_INHERITANCE.get(model)
        if accepted and accepted[0] == row:
            print(f"  {model:<40s} inherits {row}  — {accepted[1]}")
        else:
            undeclared.append((model, row))

    if undeclared:
        print()
        print("FAIL: these models keep only three of their runtime.toml")
        print("      capability fields; the rest come from a row they never named:")
        for model, row in undeclared:
            print(f"        {model} -> {row}")
        print()
        print("      Give the model its own row in")
        print("      config/agent-core-models-overlay.toml, or record the pair")
        print("      in ACCEPTED_INHERITANCE in this script with why it is safe.")
        return 1

    exact = sum(1 for m in models if m in prefixes)
    print()
    print(
        f"PASS: {len(models)} runtime models; {exact} on their own row, "
        f"{len(ACCEPTED_INHERITANCE)} declared inheritance, "
        f"{len(models) - exact - len(ACCEPTED_INHERITANCE)} with no catalog row "
        f"(these keep every declared field)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
