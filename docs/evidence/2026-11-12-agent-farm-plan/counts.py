"""Recount the agent-farm plan's audit numbers from the retained JSON files.

Usage: python3 counts.py <bundle-dir>
"""

import json
import sys
from collections import Counter
from pathlib import Path

# Requirement numbers each audit domain answered, from the audit brief (report section 2).
DOMAIN_REQUIREMENTS: dict[str, tuple[int, ...]] = {
    "keeper-continuity-time": (1,),
    "queue-proactive-attention": (23,),
    "storage-locking-io": (1, 19),
    "basepath-portability": (20,),
    "collab-knowledge-graph": (1, 21),
    "provider-protocol": (3,),
    "ocaml-architecture": (4,),
    "sandbox-remote": (5,),
    "dashboard-authz": (6,),
    "tui-core-music": (7, 18, 24),
    "lane-addon-hooks-judgement": (8, 9, 10),
    "candle-economy": (11, 24),
    "usage-observability-feedback": (12,),
    "external-tools-multimodal": (13, 17),
    "world-config-text": (14, 15),
    "tools-paradigm": (22, 10),
    "agent-dev-process-docs": (2, 16),
}
# Requirement 25 (facts, papers, named researchers) is answered by the research bundle, not an audit domain.
RESEARCH_ONLY_REQUIREMENTS: tuple[int, ...] = (25,)
REQUIREMENT_COUNT = 25
# Domains withheld because their detail states Candle payout rules (operator decision 10).
# Every other withheld row is an access-boundary finding whose fix has not merged.
PAYOUT_DOMAINS: frozenset[str] = frozenset({"candle-economy"})


def load_objects(path: Path) -> list[dict[str, object]]:
    raw: object = json.loads(path.read_text())
    if not isinstance(raw, list):
        raise SystemExit(f"{path}: expected a JSON list")
    rows: list[dict[str, object]] = []
    for item in raw:  # pyright: ignore[reportUnknownVariableType]
        if not isinstance(item, dict):
            raise SystemExit(f"{path}: expected JSON objects")
        rows.append({str(k): v for k, v in item.items()})  # pyright: ignore[reportUnknownVariableType, reportUnknownArgumentType]
    return rows


def field(row: dict[str, object], name: str) -> str:
    value = row.get(name)
    if not isinstance(value, str):
        raise SystemExit(f"row {row.get('id')}: field {name} is not a string")
    return value


def withheld_counts(rows: list[dict[str, object]]) -> str:
    withheld = [r for r in rows if "withheld" in r]
    payout = sum(1 for r in withheld if field(r, "domain") in PAYOUT_DOMAINS)
    return f"withheld {len(withheld)} (access boundary {len(withheld) - payout}, payout {payout})"


def main(bundle: Path) -> None:
    gaps = load_objects(bundle / "gaps.json")
    print("gaps", len(gaps))
    for name in ("severity_audit", "severity_after_review", "code_verdict", "flight_verdict", "kind"):
        tally = Counter(field(g, name) for g in gaps)
        print(name, dict(sorted(tally.items())))
    print(withheld_counts(gaps))

    unknown = sorted({field(g, "domain") for g in gaps} - DOMAIN_REQUIREMENTS.keys())
    if unknown:
        raise SystemExit(f"domains without a requirement mapping: {unknown}")

    print("by domain: gaps, P1 after review")
    for domain in DOMAIN_REQUIREMENTS:
        rows = [g for g in gaps if field(g, "domain") == domain]
        p1 = sum(1 for g in rows if field(g, "severity_after_review") in ("P0", "P1"))
        print(f"  {domain:30s} {len(rows):3d} {p1:3d}")

    print("by requirement: gaps, P1 after review")
    for req in range(1, REQUIREMENT_COUNT + 1):
        domains = [d for d, reqs in DOMAIN_REQUIREMENTS.items() if req in reqs]
        if not domains:
            source = "research" if req in RESEARCH_ONLY_REQUIREMENTS else "UNCOVERED"
            print(f"  {req:2d} {source}")
            continue
        rows = [g for g in gaps if field(g, "domain") in domains]
        p1 = sum(1 for g in rows if field(g, "severity_after_review") in ("P0", "P1"))
        print(f"  {req:2d} gaps={len(rows):3d} p1={p1:2d} domains={','.join(domains)}")

    print("P0/P1 after review")
    for g in gaps:
        if field(g, "severity_after_review") in ("P0", "P1"):
            print(f"  {field(g, 'id'):32s} {field(g, 'severity_after_review')} {field(g, 'title')}")

    for name in ("reviewer-additions.json", "removal-candidates.json", "open-decisions.json"):
        rows = load_objects(bundle / name)
        print(name, len(rows), withheld_counts(rows))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(Path(sys.argv[1]))
