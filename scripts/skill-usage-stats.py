#!/usr/bin/env python3
"""Cross-session Skill usage rollup from a workspace's activation ledgers.

The per-turn Skill activation evidence masc already writes
(`<base>/.masc/traces/<trace>/skill-activations.json`, schema
`masc.skill-activations/v5`) is durable but scattered one file per session, and
nothing aggregates it. The dashboard and TUI show a keeper's *current* trace
only. This operator tool walks every retained trace and reports, per Skill:
total activations, the instruction/composition split, how many distinct
sessions used it, the runtimes that served it, and when it was last used. It
also lists installed Skills that never activated.

This is a read-only reporting stopgap; a first-class rollup surfaced in the TUI
Runtime view and the dashboard is the durable target (see the accompanying RFC).

Usage:
  scripts/skill-usage-stats.py [--base-path DIR] [--json]

  --base-path  workspace root holding .masc/ (default: $MASC_BASE_PATH or cwd)
  --json       emit the rollup as JSON instead of a table
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any, Iterator

SCHEMA_PREFIX = "masc.skill-activations/"


@dataclass
class SkillRow:
    total: int = 0
    instruction: int = 0
    composition: int = 0
    sessions: set[str] = field(default_factory=set)
    runtimes: set[str] = field(default_factory=set)
    last_used: str = ""


def load_activations(base_path: str) -> Iterator[tuple[str, dict[str, Any]]]:
    """Yield (session_id, activation) for every activation in every trace."""
    pattern = os.path.join(base_path, ".masc", "traces", "*", "skill-activations.json")
    for fp in sorted(glob.glob(pattern)):
        try:
            with open(fp, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"warn: skipping {fp}: {exc}", file=sys.stderr)
            continue
        if not str(doc.get("schema", "")).startswith(SCHEMA_PREFIX):
            continue
        session_id = doc.get("session_id", os.path.basename(os.path.dirname(fp)))
        for act in doc.get("activations", []):
            yield session_id, act


def installed_skill_names(base_path):
    """Names declared in SKILL.md frontmatter under the default source roots."""
    home = os.path.expanduser("~")
    roots = [
        os.path.join(base_path, ".masc", "skills"),
        os.path.join(base_path, ".agents", "skills"),
        os.path.join(home, ".masc", "skills"),
        os.path.join(home, ".agents", "skills"),
    ]
    names = set()
    for root in roots:
        for skill_md in glob.glob(os.path.join(root, "**", "SKILL.md"), recursive=True):
            try:
                with open(skill_md, encoding="utf-8") as fh:
                    in_fm = False
                    for line in fh:
                        s = line.strip()
                        if s == "---":
                            if in_fm:
                                break
                            in_fm = True
                            continue
                        if in_fm and s.startswith("name:"):
                            names.add(s[len("name:"):].strip().strip('"').strip("'"))
                            break
            except OSError:
                continue
    return names


def rollup(base_path: str) -> tuple[dict[str, SkillRow], int, set[str]]:
    per_skill: dict[str, SkillRow] = defaultdict(SkillRow)
    total = 0
    sessions_seen: set[str] = set()
    for session_id, act in load_activations(base_path):
        ident = act.get("identity", {})
        name = ident.get("name") or ident.get("package_id") or "<unknown>"
        row = per_skill[name]
        row.total += 1
        total += 1
        sessions_seen.add(session_id)
        row.sessions.add(session_id)
        kind = (act.get("invocation") or {}).get("kind", "")
        if kind == "instruction":
            row.instruction += 1
        elif kind == "composition":
            row.composition += 1
        delivery = act.get("delivery") or {}
        if delivery.get("runtime_id"):
            row.runtimes.add(delivery["runtime_id"])
        at = act.get("activated_at", "")
        if at > row.last_used:
            row.last_used = at
    return per_skill, total, sessions_seen


def main(argv=None):
    parser = argparse.ArgumentParser(description="Cross-session Skill usage rollup.")
    parser.add_argument("--base-path", default=os.environ.get("MASC_BASE_PATH", "."))
    parser.add_argument("--json", action="store_true", dest="as_json")
    args = parser.parse_args(argv)

    base = os.path.abspath(os.path.expanduser(args.base_path))
    per_skill, total, sessions = rollup(base)
    installed = installed_skill_names(base)
    used = set(per_skill)
    unused = sorted(installed - used)

    ranked = sorted(per_skill.items(), key=lambda kv: kv[1].total, reverse=True)

    if args.as_json:
        out = {
            "base_path": base,
            "total_activations": total,
            "sessions": len(sessions),
            "skills": [
                {
                    "name": name,
                    "total": r.total,
                    "instruction": r.instruction,
                    "composition": r.composition,
                    "sessions": len(r.sessions),
                    "runtimes": sorted(r.runtimes),
                    "last_used": r.last_used,
                }
                for name, r in ranked
            ],
            "installed_unused": unused,
        }
        json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return 0

    if total == 0:
        print(f"No Skill activations found under {base}/.masc/traces/.")
        if not installed:
            print("No Skills are installed in the default source roots either.")
        return 0

    print(f"Skill usage across {len(sessions)} sessions — {total} activations")
    print(f"  workspace: {base}\n")
    print(f"  {'skill':32} {'total':>6} {'instr':>6} {'compo':>6} {'sess':>5}  last used")
    print(f"  {'-'*32} {'-'*6} {'-'*6} {'-'*6} {'-'*5}  {'-'*20}")
    for name, r in ranked:
        print(f"  {name:32.32} {r.total:>6} {r.instruction:>6} "
              f"{r.composition:>6} {len(r.sessions):>5}  {r.last_used}")
    if unused:
        print(f"\n  installed but never activated ({len(unused)}): {', '.join(unused)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
