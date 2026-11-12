# pyright: strict
"""Count an E-synth label audit's cases by how each was picked and whether its label misfit the judge.

    python3 audit_strata.py <audit dir>

Reads <audit dir>/audit.json (`e_synth_audit.py apply`) and <audit dir>/key.jsonl. A case was picked
as a `disagreement` when the baseline's valid answer differed from the label, and as a `sample` when
the answer agreed with the label or was not valid. Prints counts only.
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path
from typing import cast

type JsonObject = dict[str, object]


def main() -> int:
    audit = Path(sys.argv[1])
    done = cast(JsonObject, json.loads((audit / "audit.json").read_text(encoding="utf-8")))
    cases = cast(list[JsonObject], done["per_case"])
    keys = [cast(JsonObject, json.loads(line))
            for line in (audit / "key.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
    if [k["case"] for k in keys] != [c["case"] for c in cases]:
        raise SystemExit("key.jsonl and audit.json list different cases")
    counts: Counter[tuple[str, str]] = Counter()
    for case in cases:
        misfit = ("candidate" if case["request_misfits"] else "") + ("+memory" if case["memory_misfits"] else "")
        counts[(cast(str, case["picked"]), misfit.removeprefix("+") or "none")] += 1
    for picked in sorted({p for p, _ in counts}):
        total = sum(n for (p, _), n in counts.items() if p == picked)
        misfits = total - counts[(picked, "none")]
        print(json.dumps({"picked": picked, "cases": total, "misfit": misfits, "rate": round(misfits / total, 4),
                          "by_kind": {kind: n for (p, kind), n in sorted(counts.items()) if p == picked}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
