"""Keeper-name redaction shared by the capture-tui-* scripts.

A terminal is a fixed-width grid, so a stand-in for a name has the name's
length: a shorter one would shift every cell after it on the row. A table
column also truncates a long name to fit, and the truncated form no longer
matches a rule written for the full name, so the rules cover every prefix a
column can show, not only the name.
"""

from __future__ import annotations

from pathlib import Path

# A prefix shorter than this is too generic to redact safely; no keeper column
# truncates a name above ~18 cells (the actor column keeps 15 and adds a mark),
# so 12 covers every truncation in practice.
MIN_PREFIX_LEN = 12


def placeholder_for(name: str, index: int) -> str:
    """A distinct stand-in of exactly len(name) characters."""
    # `kpr-01` needs six cells. A shorter name gets the compact `k01` form so
    # two different keepers never truncate onto the same token.
    base = f"kpr-{index:02d}" if len(name) >= 6 else f"k{index:02d}"
    if len(base) >= len(name):
        return base[: len(name)]
    return base + " " * (len(name) - len(base))


def discover_keeper_names(base_path: Path) -> list[str]:
    keepers = base_path / ".masc" / "keepers"
    if not keepers.is_dir():
        return []
    return sorted(
        (
            d.name
            for d in keepers.iterdir()
            if d.is_dir() and not d.name.startswith(".")
        ),
        key=len,
        reverse=True,
    )


def displayable_prefixes(name: str) -> list[str]:
    """The proper prefixes of ``name`` a column can show, shortest first."""
    return [name[:cut] for cut in range(MIN_PREFIX_LEN, len(name))]


def redaction_pairs(names: list[str]) -> list[list[str]]:
    """``[from, to]`` pairs for the page's redaction script, longest first.

    Each full name maps to its placeholder and each displayable prefix to the
    same placeholder cut to the prefix's length. A prefix that is also another
    keeper's full name is left to that keeper's own pair, and a prefix two
    keepers share goes to the first of them, so one text never has two
    stand-ins.
    """
    full_names = set(names)
    pairs: list[list[str]] = []
    seen: set[str] = set()
    for index, name in enumerate(names):
        placeholder = placeholder_for(name, index + 1)
        if name not in seen:
            seen.add(name)
            pairs.append([name, placeholder])
        for prefix in displayable_prefixes(name):
            if prefix in full_names or prefix in seen:
                continue
            seen.add(prefix)
            pairs.append([prefix, placeholder[: len(prefix)]])
    pairs.sort(key=lambda pair: len(pair[0]), reverse=True)
    return pairs


def leaked_names(names: list[str], screen_text: str) -> list[str]:
    """Names whose full text, or a displayable prefix of it, is still on screen."""
    return [
        name
        for name in names
        if name in screen_text
        or any(prefix in screen_text for prefix in displayable_prefixes(name))
    ]
