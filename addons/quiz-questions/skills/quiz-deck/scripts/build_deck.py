#!/usr/bin/env python3
"""Build a quiz fact deck from candidate facts and the record text they quote.

Usage: build_deck.py CANDIDATES.json RECORD_DIR DECK_ID OUT.json

Each candidate: {"id", "field", "subject", "answer", "quote",
                 "record": {"uri", "file"}}
`file` names a text file in RECORD_DIR holding the record exactly as it was read
(for Board: the masc_board_post_get text). A candidate is accepted only when
  answer ⊂ quote ⊂ record bytes
so the right answer is literally in the words the record says. The deck keeps
the record file's SHA-256; it does not claim that the file equals the Board's
stored bytes, only that this capture was what the Keeper read.
Rejected candidates are listed in the deck's `detail` and make it incomplete.
"""
from __future__ import annotations

import hashlib
import json
import sys
import time
from pathlib import Path


def build(candidates: list[dict], record_dir: Path, deck_id: str) -> tuple[dict, list[str]]:
    facts, rejected = [], []
    for item in candidates:
        ident = item.get("id", "?")
        try:
            path = record_dir / item["record"]["file"]
            data = path.read_bytes()
            quote, answer = item["quote"], item["answer"]
            if not quote or not answer:
                raise ValueError("empty quote or answer")
            if quote.encode() not in data:
                raise ValueError("quote is not in the record")
            if answer not in quote:
                raise ValueError("answer is not in the quote")
            facts.append({"id": ident, "kind": "fact", "observed_at": time.time(),
                          "actor": item.get("actor"), "field": item["field"],
                          "subject": item["subject"], "answer": answer, "quote": quote,
                          "record": {"uri": item["record"]["uri"],
                                     "sha256": hashlib.sha256(data).hexdigest()}})
        except (KeyError, OSError, ValueError) as error:
            rejected.append(f"{ident}: {error}")
    deck = {"source_id": "deck", "incarnation": deck_id, "cursor": None,
            "complete": not rejected,
            "detail": ("rejected " + "; ".join(rejected)) if rejected else None,
            "observations": facts}
    return deck, rejected


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    candidates = json.loads(Path(argv[1]).read_text())
    deck, rejected = build(candidates, Path(argv[2]), argv[3])
    Path(argv[4]).write_text(json.dumps(deck, ensure_ascii=False, indent=1) + "\n")
    print(f"accepted {len(deck['observations'])}, rejected {len(rejected)}")
    for line in rejected:
        print("  ✗", line)
    return 1 if rejected else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
