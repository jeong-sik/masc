"""Resolve a manifest's mutable Tool_calls day link after segment rotation."""

from datetime import date
from pathlib import Path
import re


def tool_call_log_paths(base_path: Path, path: Path) -> list[Path]:
    """Expand only this workspace's canonical DD.jsonl link to its day files.

    Other links, including an explicit completed segment, retain their exact
    single-file authority. A missing current file does not hide its segments.
    """
    root = (base_path / ".masc" / "tool_calls").absolute()
    try:
        relative = path.absolute().relative_to(root)
    except ValueError:
        return [path] if path.is_file() else []
    if (len(relative.parts) != 2
            or not re.fullmatch(r"[0-9]{4}-[0-9]{2}", relative.parts[0])
            or not re.fullmatch(r"[0-9]{2}\.jsonl", path.name)):
        return [path] if path.is_file() else []
    month, _ = relative.parts
    try:
        date.fromisoformat(f"{month}-{path.stem}")
    except ValueError:
        return [path] if path.is_file() else []
    if path.is_symlink() or path.parent.resolve() != root.resolve() / month:
        return [path] if path.is_file() else []
    if path.exists() and not path.is_file():
        return []

    segments = []
    for candidate in path.parent.glob(f"{path.stem}.*.jsonl"):
        match = re.fullmatch(rf"{path.stem}\.([0-9]+)\.jsonl", candidate.name)
        if match is None:
            continue
        digits = match[1]
        sequence = int(digits)
        if (sequence > 0 and digits == f"{sequence:03d}"
                and candidate.is_file() and not candidate.is_symlink()):
            segments.append((sequence, candidate))
    paths = [candidate for _, candidate in sorted(segments)]
    if path.is_file():
        paths.append(path)
    return paths
