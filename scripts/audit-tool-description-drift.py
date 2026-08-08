#!/usr/bin/env python3
"""Fail when a tool's description exists in two places and they disagree.

A tool description is a prompt: it is what the model reads when deciding
whether to call the tool. Two of them exist for some tools:

    lib/keeper/keeper_tool_descriptor.ml   what production hands the model,
                                           through model_visible_schemas ()
    lib/tool_surface/*.ml                  the shard catalog

Only the first reaches a Keeper. PR #27542 edited the second, added a test that
read the second, and passed while proving nothing about what any Keeper sees --
the reviewer closed it for exactly that. This audit is that review, mechanised.

At the time of writing, 11 tools carry a description in both places and 9 of
them already differ. That is the baseline: the number may not grow. Lowering it
is the work; this only stops it rising.

Extraction is deliberately narrow -- name-literal descriptors with a literal
description. Descriptors built by a helper (the Board family, the Library
family) resolve their text through the canonical registry and are not a second
copy, so they are outside the comparison and outside the baseline.

Usage:
    scripts/audit-tool-description-drift.py           # report, exit 1 above baseline
    scripts/audit-tool-description-drift.py --list    # report, always exit 0
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Tools whose two descriptions already disagree. This is a ceiling, not a
# target: a new divergence fails, and fixing one should lower the number.
DRIFT_BASELINE = 9

PRODUCTION = REPO_ROOT / "lib" / "keeper" / "keeper_tool_descriptor.ml"
SHARD_GLOB = "lib/tool_surface/*.ml"

PRODUCTION_RE = re.compile(
    r'~name:"([a-z_0-9]+)"\s*\n?\s*~description:\s*\n?\s*"((?:[^"\\]|\\.)*)"',
    re.S,
)
SHARD_RE = re.compile(
    r'\{\s*name = "([a-z_0-9]+)"\s*;\s*description =\s*\n?\s*"((?:[^"\\]|\\.)*)"',
    re.S,
)


def normalise(text: str) -> str:
    """OCaml line continuations and wrapping are not content."""
    return re.sub(r"\s+", " ", re.sub(r"\\\s*\n\s*", "", text)).strip()


def descriptions(path: Path, pattern: re.Pattern[str]) -> dict[str, str]:
    try:
        source = path.read_text(errors="ignore")
    except OSError:
        return {}
    return {m.group(1): normalise(m.group(2)) for m in pattern.finditer(source)}


def collect() -> tuple[dict[str, str], dict[str, str]]:
    production = descriptions(PRODUCTION, PRODUCTION_RE)
    shard: dict[str, str] = {}
    for path in sorted(REPO_ROOT.glob(SHARD_GLOB)):
        shard.update(descriptions(path, SHARD_RE))
    return production, shard


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--list",
        action="store_true",
        help="Report and exit 0, for inspecting the current state.",
    )
    args = parser.parse_args()

    production, shard = collect()
    shared = sorted(set(production) & set(shard))
    drifted = [name for name in shared if production[name] != shard[name]]

    print(
        f"[tool-description-drift] {len(shared)} tool(s) described in both "
        f"keeper_tool_descriptor.ml and lib/tool_surface/, "
        f"{len(drifted)} disagreeing"
    )

    if drifted:
        print("\nthe model reads the keeper_tool_descriptor.ml text; the other is unread:\n")
        for name in drifted:
            print(f"  {name}")
            print(f"    production: {production[name][:110]}")
            print(f"    shard     : {shard[name][:110]}")

    if args.list:
        return 0

    if len(drifted) > DRIFT_BASELINE:
        print(
            f"\n[tool-description-drift] {len(drifted)} exceeds the baseline of "
            f"{DRIFT_BASELINE}.\n"
            "A description is what the model reads when choosing a tool. Edit the "
            "one in\nkeeper_tool_descriptor.ml -- that is the copy production "
            "hands a Keeper -- or\nmake both say the same thing."
        )
        return 1

    if len(drifted) < DRIFT_BASELINE:
        print(
            f"\n[tool-description-drift] OK - {len(drifted)} drifted, "
            f"{DRIFT_BASELINE} baseline - lower DRIFT_BASELINE to hold the "
            f"{DRIFT_BASELINE - len(drifted)} you fixed"
        )
        return 0

    print(f"\n[tool-description-drift] OK - {len(drifted)} drifted, at baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
