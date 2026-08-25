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
import time
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


IDLE_HOURS = 12.0
"""A keeper that has not taken a turn in this long is treated as stopped.

Names do not decide this.  The adm-race keepers read like leftover test
fixtures and were in fact turning every few minutes, so classifying by
name prefix counted live work as residue.  Last turn is the fact; the
name is a hint about why it exists.
"""


def default_masc_root() -> str | None:
    """Runtime store root from the environment, or nothing.

    The store lives under whatever base path the deployment chose, so this
    returns None rather than guessing a home directory; the caller then has to
    pass --masc-root explicitly.
    """
    base = os.environ.get("MASC_BASE_PATH")
    return os.path.join(base, ".masc") if base else None


def keeper_role(name: str) -> str:
    if name.startswith("rw-e0-"):
        return "campaign_round"
    if name.startswith("canary-"):
        return "canary_sweep"
    if name.startswith("adm-race-"):
        return "admission_probe"
    return "operational"


def read_keepers(masc_root: str, now: float | None = None) -> dict:
    keeper_dir = os.path.join(masc_root, "keepers")
    census = {"live": [], "idle": []}
    if not os.path.isdir(keeper_dir):
        return census
    now = now if now is not None else time.time()
    for entry in sorted(os.listdir(keeper_dir)):
        if not entry.endswith(".json"):
            continue
        name = entry[: -len(".json")]
        try:
            with open(os.path.join(keeper_dir, entry), encoding="utf-8") as handle:
                state = json.load(handle)
        except (OSError, ValueError):
            state = {}
        try:
            last_turn = float(state.get("last_turn_ts") or 0)
        except (TypeError, ValueError):
            last_turn = 0.0
        idle_h = (now - last_turn) / 3600 if last_turn else None
        record = {
            "name": name,
            "role": keeper_role(name),
            "idle_hours": round(idle_h, 1) if idle_h is not None else None,
            "paused": bool(state.get("paused")),
        }
        stopped = idle_h is None or idle_h >= IDLE_HOURS
        census["idle" if stopped else "live"].append(record)
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
    parser.add_argument(
        "--masc-root",
        default=default_masc_root(),
        help=(
            "runtime store root; defaults to <MASC_BASE_PATH>/.masc when that "
            "is set. There is no built-in path — this tool is not tied to one "
            "person's home directory."
        ),
    )
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

    if not args.masc_root:
        parser.error(
            "--masc-root is required (or set MASC_BASE_PATH); the keeper store "
            "path is deployment-specific"
        )

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
