#!/usr/bin/env python3
"""Add @stability annotation to .mli files.

Usage:
    python3 scripts/annotate_stability.py <tier> <file1.mli> [file2.mli ...]

    tier: Stable | Evolving | Internal

Examples:
    python3 scripts/annotate_stability.py Stable lib/types.mli lib/error.mli
    python3 scripts/annotate_stability.py Internal lib/llm_provider/*.mli
"""

import re
import sys
from pathlib import Path

VALID_TIERS = {"Stable", "Evolving", "Internal"}
SINCE_VERSION = "0.93.1"


def add_annotation(filepath: Path, tier: str) -> bool:
    """Add @stability to a .mli file. Returns True if modified."""
    text = filepath.read_text()

    # Already annotated?
    if "@stability" in text:
        print(f"  SKIP {filepath} (already annotated)")
        return False

    # Pattern 1: file starts with (** ... *) doc comment
    # Find the first top-level doc comment
    m = re.match(r"(\(\*\*[\s\S]*?\*\))", text)
    if m:
        old_comment = m.group(1)
        # Insert before closing *)
        # Handle both single-line and multi-line
        if old_comment.endswith("*)"):
            # Find the position of the last *)
            insert_pos = old_comment.rfind("*)")
            before = old_comment[:insert_pos].rstrip()
            # Determine indentation (usually 4 spaces for odoc)
            annotation = f"\n\n    @stability {tier}\n    @since {SINCE_VERSION} "
            new_comment = before + annotation + "*)"
            text = text.replace(old_comment, new_comment, 1)
        filepath.write_text(text)
        print(f"  DONE {filepath} -> {tier} (updated existing comment)")
        return True

    # Pattern 2: no doc comment at top — add one
    # Derive a brief description from the filename
    stem = filepath.stem  # e.g., "types" from "types.mli"
    desc = stem.replace("_", " ").capitalize()
    new_comment = (
        f"(** {desc}.\n"
        f"\n"
        f"    @stability {tier}\n"
        f"    @since {SINCE_VERSION} *)\n\n"
    )
    text = new_comment + text
    filepath.write_text(text)
    print(f"  DONE {filepath} -> {tier} (added new comment)")
    return True


def main() -> None:
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    tier = sys.argv[1]
    if tier not in VALID_TIERS:
        print(f"Error: tier must be one of {VALID_TIERS}, got '{tier}'")
        sys.exit(1)

    files = [Path(f) for f in sys.argv[2:]]
    modified = 0
    for f in files:
        if not f.exists():
            print(f"  WARN {f} does not exist, skipping")
            continue
        if not f.suffix == ".mli":
            print(f"  WARN {f} is not .mli, skipping")
            continue
        if add_annotation(f, tier):
            modified += 1

    print(f"\n{modified}/{len(files)} files annotated with @stability {tier}")


if __name__ == "__main__":
    main()
