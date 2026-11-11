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

A snapshot is the only copy of its records once the server removed their text.
When it is lost, `--of <the manifest>` takes that manifest's records again from
a base that still holds them, the server's or another snapshot:

    uv run scripts/tinker/librarian/e_real_manifest.py --base <base> --of <manifest> \
        --snapshot artifacts/tinker/librarian/e-real-snapshot --out <manifest>

Only the records `--of` lists are copied, each with the bytes it pins. The new
manifest names the earlier one by sha256 and lists, under `of.gone`, the digests
of its records the base no longer holds. E-real is then the records left.
`--out` may be the `--of` file: it is read before anything is written.
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
    ap.add_argument("--of", default=None,
                    help="an earlier manifest: take only its records, the ones the base still holds")
    args = ap.parse_args()
    snapshot = Path(cast(str, args.snapshot))
    of = cast(str | None, args.of)
    earlier = None if of is None else E.earlier_manifest(Path(of))
    records = E.snapshot(E.base_path(cast(str | None, args.base)), snapshot, earlier)
    created = dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = Path(cast(str, args.out))
    out.write_text(json.dumps(E.manifest_of(records, created, earlier), indent=1) + "\n", encoding="utf-8")
    gone = "" if earlier is None else f", {len(earlier.items) - len(records)} of the earlier {len(earlier.items)} gone"
    print(f"{len(records)} records -> {snapshot}, {out}{gone}")


if __name__ == "__main__":
    main()
