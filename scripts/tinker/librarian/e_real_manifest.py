# /// script
# requires-python = ">=3.12"
# ///
# pyright: strict
"""Snapshot the answered admission records and write the E-real manifest of the snapshot.

    MASC_BASE_PATH=<base> uv run scripts/tinker/librarian/e_real_manifest.py \
        --snapshot artifacts/tinker/librarian/e-real-snapshot \
        --out scripts/tinker/librarian/e_real_manifest.json

E-real is every answered keeper-librarian admission record in the store when
the snapshot is taken. Records answered later are not in it. The server later
removes the text of finished admissions from its store, so the snapshot copies
each record's bytes under `--snapshot` (`exact_store.snapshot`), and E-real
runs read it with MASC_BASE_PATH=<snapshot>. The snapshot holds request and
answer text: keep it under `artifacts/`, which git ignores. The manifest holds
each record's digest and file sha256, never request or answer text.
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
    ap.add_argument("--snapshot", required=True, help="base path of the copy E-real runs read; it holds no records yet")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    snapshot = Path(cast(str, args.snapshot))
    records = E.snapshot(E.base_path(cast(str | None, args.base)), snapshot)
    created = dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = Path(cast(str, args.out))
    out.write_text(json.dumps(E.manifest_of(records, created), indent=1) + "\n", encoding="utf-8")
    print(f"{len(records)} records -> {snapshot}, {out}")


if __name__ == "__main__":
    main()
