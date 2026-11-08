# /// script
# requires-python = ">=3.12"
# ///
# pyright: strict
"""Write the E-real manifest from the exact-request store.

    MASC_BASE_PATH=<base> uv run scripts/tinker/librarian/e_real_manifest.py \
        --out scripts/tinker/librarian/e_real_manifest.json

E-real is every answered keeper-librarian admission record in the store when
the manifest is written. Records answered later are not in it. The manifest
holds each record's digest and file sha256, never request or answer text.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
from typing import cast

import exact_store as E


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=None, help="MASC base path (default: MASC_BASE_PATH)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    records = E.answered_admissions(E.base_path(cast(str | None, args.base)))
    created = dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = Path(cast(str, args.out))
    out.write_text(json.dumps(E.manifest_of(records, created), indent=1) + "\n", encoding="utf-8")
    print(f"{len(records)} records -> {out}")


if __name__ == "__main__":
    main()
