"""Recount the prior-art research numbers from the retained digests.

Usage: python3 counts.py <bundle-dir>
"""

import json
import sys
from collections import Counter
from pathlib import Path

LIST_FIELDS: tuple[str, ...] = ("findings", "not_applicable", "unknowns", "conflicts_with_brief")


def load_digest(path: Path) -> dict[str, object]:
    raw: object = json.loads(path.read_text())
    if not isinstance(raw, dict):
        raise SystemExit(f"{path}: expected a JSON object")
    return {str(k): v for k, v in raw.items()}  # pyright: ignore[reportUnknownVariableType, reportUnknownArgumentType]


def items(digest: dict[str, object], name: str, path: Path) -> list[object]:
    value = digest.get(name)
    if not isinstance(value, list):
        raise SystemExit(f"{path}: field {name} is not a list")
    return list(value)  # pyright: ignore[reportUnknownArgumentType]


def check_verdict(finding: object, path: Path) -> str:
    if not isinstance(finding, dict):
        raise SystemExit(f"{path}: a finding is not an object")
    check = finding.get("check")  # pyright: ignore[reportUnknownMemberType, reportUnknownVariableType]
    if not isinstance(check, str):
        raise SystemExit(f"{path}: a finding has no check verdict")
    return check.split(" ")[0].split(":")[0]


def main(bundle: Path) -> None:
    totals: Counter[str] = Counter()
    sizes: Counter[str] = Counter()
    for path in sorted(bundle.glob("*.digest.json")):
        digest = load_digest(path)
        verdicts = Counter(check_verdict(f, path) for f in items(digest, "findings", path))
        totals.update(verdicts)
        for name in LIST_FIELDS:
            sizes[name] += len(items(digest, name, path))
        print(f"{path.name:45s} {dict(sorted(verdicts.items()))}")
    print("check verdicts", dict(sorted(totals.items())))
    print("sizes", dict(sizes))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(Path(sys.argv[1]))
