# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Print the base model's E-synth summary on the 142 requests the audit kept.

    uv run docs/evidence/research/2026-11-09-tinker-librarian-admission-baseline/final_summary.py

Reads e-synth-base-rows.jsonl and e-synth-audit.json next to this file and
prints `eval_admission.summarize` over the rows whose item the audit did not
remove. Writes nothing.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / "scripts" / "tinker" / "librarian"))

import eval_admission as V

type JsonObject = dict[str, object]

HERE = Path(__file__).resolve().parent

audit = cast(JsonObject, json.loads((HERE / "e-synth-audit.json").read_text(encoding="utf-8")))
removed = set(cast(list[str], audit["removed_items"]))
rows = [cast(JsonObject, json.loads(line))
        for line in (HERE / "e-synth-base-rows.jsonl").read_text(encoding="utf-8").splitlines()]
kept = [r for r in rows if r["item"] not in removed]
print(json.dumps({"items": len(kept), **cast(JsonObject, V.summarize("synth", kept)["base"])}, indent=1))
