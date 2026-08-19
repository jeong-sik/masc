#!/usr/bin/env python3
"""Extract MASC progress numbers from measured sources.

Every number this emits is read from a file that a run produced.  Nothing is
typed in by hand, so a stale figure means a stale source, not a stale edit.

Sources:
  feature matrix HTML  -> 47 feature rows, their required vs evidenced axes,
                          and the 12 product-scenario rows
  mission catalog JSON -> the RW mission list
  campaign report dirs -> per-round assertion and mission tallies
  keeper store         -> live vs residue keeper census
  parity matrix MD     -> constitution/code gap tally (absent until merged)
"""

from __future__ import annotations

import argparse
import json
import os
import re
from dataclasses import dataclass, field, asdict


FEATURE_ROW_RE = re.compile(
    r'<tr data-domain="([^"]*)" data-required="([^"]*)" data-evidence="([^"]*)">(.*?)</tr>',
    re.S,
)
CELL_RE = re.compile(r"<t[dh][^>]*>(.*?)</t[dh]>", re.S)
ROW_RE = re.compile(r"<tr[^>]*>(.*?)</tr>", re.S)
TAG_RE = re.compile(r"<[^>]+>")


def strip_tags(fragment: str) -> str:
    return TAG_RE.sub("", fragment).strip()


@dataclass
class FeatureRow:
    domain: str
    feature: str
    status: str
    required: list
    evidenced: list
    missing: list


@dataclass
class ScenarioRow:
    name: str
    success: str
    needs: str
    status: str
    evidence: str
    missing_execution: str


@dataclass
class Round:
    run_id: str
    assertions_passed: int
    assertions_total: int
    missions_passed: int = 0
    missions_total: int = 0
    failed_missions: list = field(default_factory=list)


def read_feature_rows(matrix_html: str) -> list:
    rows = []
    for domain, required, evidence, body in FEATURE_ROW_RE.findall(matrix_html):
        cells = [strip_tags(c) for c in CELL_RE.findall(body)]
        req = required.split()
        ev = evidence.split()
        rows.append(
            FeatureRow(
                domain=domain,
                feature=cells[1] if len(cells) > 1 else "",
                status=cells[2] if len(cells) > 2 else "",
                required=req,
                evidenced=ev,
                missing=sorted(set(req) - set(ev)),
            )
        )
    return rows


def read_scenario_rows(matrix_html: str) -> list:
    anchor = matrix_html.find("팀 시나리오 검증 매트릭스")
    if anchor < 0:
        return []
    segment = matrix_html[anchor : anchor + 20000]
    rows = []
    for body in ROW_RE.findall(segment):
        cells = [strip_tags(c) for c in CELL_RE.findall(body)]
        if len(cells) < 6 or cells[0] == "시나리오":
            continue
        rows.append(
            ScenarioRow(
                name=cells[0],
                success=cells[1],
                needs=cells[2],
                status=cells[3],
                evidence=cells[4],
                missing_execution=cells[5],
            )
        )
    return rows


def read_missions(catalog_path: str) -> list:
    with open(catalog_path, encoding="utf-8") as handle:
        catalog = json.load(handle)
    return [
        {
            "id": m["id"],
            "phase": m.get("phase", ""),
            "name": m.get("name", ""),
            "assertions": m.get("assertions", []),
            "capabilities": m.get("capabilities", []),
        }
        for m in catalog.get("missions", [])
    ]


def read_rounds(reports_dir: str) -> list:
    if not os.path.isdir(reports_dir):
        return []
    rounds = []
    for entry in sorted(os.listdir(reports_dir)):
        run_dir = os.path.join(reports_dir, entry)
        assertions_path = os.path.join(run_dir, "assertions.json")
        if not os.path.isfile(assertions_path):
            continue
        with open(assertions_path, encoding="utf-8") as handle:
            assertions = json.load(handle)
        rnd = Round(
            run_id=entry,
            assertions_passed=sum(1 for v in assertions.values() if v.get("passed")),
            assertions_total=len(assertions),
        )
        bundle_path = os.path.join(run_dir, "bundle.md")
        if os.path.isfile(bundle_path):
            with open(bundle_path, encoding="utf-8") as handle:
                bundle = handle.read()
            for line in bundle.splitlines():
                if not line.startswith("| RW"):
                    continue
                cols = [c.strip() for c in line.strip("|").split("|")]
                if len(cols) < 3:
                    continue
                rnd.missions_total += 1
                if cols[2] == "passed":
                    rnd.missions_passed += 1
                else:
                    rnd.failed_missions.append(cols[0])
        rounds.append(rnd)
    return rounds


def classify_keeper(name: str) -> str:
    if name.startswith("rw-e0-"):
        return "campaign_round"
    if name.startswith("canary-"):
        return "canary_sweep"
    if name.startswith("adm-race-"):
        return "race_test"
    return "operational"


def read_keepers(masc_root: str) -> dict:
    keeper_dir = os.path.join(masc_root, "keepers")
    census = {"operational": [], "campaign_round": [], "canary_sweep": [], "race_test": []}
    if not os.path.isdir(keeper_dir):
        return census
    for entry in sorted(os.listdir(keeper_dir)):
        if not entry.endswith(".json"):
            continue
        name = entry[: -len(".json")]
        census[classify_keeper(name)].append(name)
    return census


PARITY_SECTION_RE = re.compile(r"^## ([A-D])\. (.+)$", re.M)
PARITY_ROW_RE = re.compile(r"^\| ([ABCD]\d+) \| (.+?) \| (.+?) \| (.+?) \|$", re.M)


def read_parity(parity_path: str) -> dict:
    if not os.path.isfile(parity_path):
        return {"available": False, "rows": []}
    with open(parity_path, encoding="utf-8") as handle:
        text = handle.read()
    rows = [
        {"id": rid, "item": item, "evidence": evidence, "status": status}
        for rid, item, evidence, status in PARITY_ROW_RE.findall(text)
    ]
    sections = {letter: title for letter, title in PARITY_SECTION_RE.findall(text)}
    return {"available": True, "rows": rows, "sections": sections}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--reports-dir")
    parser.add_argument("--masc-root", default=os.path.expanduser("~/me/.masc"))
    parser.add_argument(
        "--parity-path",
        help="constitution/code parity matrix; defaults to the copy under --repo-root",
    )
    parser.add_argument("--out")
    args = parser.parse_args()

    repo = args.repo_root
    reports_dir = args.reports_dir or os.path.join(repo, "reports")
    matrix_path = os.path.join(
        repo, "docs/design/keeper-feature-state-matrix-2026-08-13.html"
    )
    with open(matrix_path, encoding="utf-8") as handle:
        matrix_html = handle.read()

    payload = {
        "feature_rows": [asdict(r) for r in read_feature_rows(matrix_html)],
        "scenario_rows": [asdict(r) for r in read_scenario_rows(matrix_html)],
        "missions": read_missions(
            os.path.join(repo, "scripts/fixtures/keeper-multi-collaboration/missions.json")
        ),
        "rounds": [asdict(r) for r in read_rounds(reports_dir)],
        "keepers": read_keepers(args.masc_root),
        "parity": read_parity(
            args.parity_path
            or os.path.join(repo, "docs/audits/constitution-code-parity-matrix.md")
        ),
        "sources": {
            "matrix": matrix_path,
            "reports_dir": reports_dir,
            "masc_root": args.masc_root,
        },
    }

    text = json.dumps(payload, ensure_ascii=False, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    else:
        print(text)


if __name__ == "__main__":
    main()
