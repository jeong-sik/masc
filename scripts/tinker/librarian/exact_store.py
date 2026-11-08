# pyright: strict
"""Read answered keeper-librarian admission records from the exact-request store.

The store is <base>/.masc/lane-addons/exact-requests/<scope>/<digest>.json and
belongs to the running server. This module only reads it. A record holds the
request MASC sent (one user message and the output JSON Schema) and, once a
slot answered, the accepted answer in `final.output`.

The E-real manifest names records by digest and pins each file's bytes with
sha256. It holds no request or answer text, so it can be committed.
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import cast

DECLARATION = "keeper-librarian"
OUTPUT = "admission"
MANIFEST_SCHEMA = "masc.tinker.librarian.e_real_manifest.v1"

type JsonObject = dict[str, object]


@dataclass(frozen=True, slots=True)
class AnsweredAdmission:
    digest: str
    sha256: str
    prompt: str  # the one user message MASC sent
    schema: JsonObject  # the output JSON Schema MASC sent
    answer: JsonObject  # the answer MASC accepted
    slot: str  # the slot that answered


def base_path(arg: str | None) -> Path:
    raw = arg or os.environ.get("MASC_BASE_PATH")
    if not raw:
        raise SystemExit("pass --base or set MASC_BASE_PATH")
    return Path(raw).expanduser()


def store_dir(base: Path) -> Path:
    return base / ".masc" / "lane-addons" / "exact-requests"


def _object(value: object) -> JsonObject | None:
    return cast(JsonObject, value) if isinstance(value, dict) else None


def read_record(path: Path) -> AnsweredAdmission | None:
    """The record when it is an answered admission of keeper-librarian, else None."""
    raw = path.read_bytes()
    rec = _object(json.loads(raw))
    if rec is None or rec.get("declaration_id") != DECLARATION:
        return None
    request, final = _object(rec.get("request")), _object(rec.get("final"))
    if request is None or final is None or request.get("output") != OUTPUT or final.get("status") != "answered":
        return None
    schema, answer, messages = _object(request.get("schema")), _object(final.get("output")), request.get("messages")
    digest, slot = rec.get("digest"), final.get("slot")
    if schema is None or answer is None or not isinstance(digest, str) or not isinstance(slot, str):
        return None
    # Every admission request so far is one user message without a system field.
    # Another shape would reach the wire differently, so it stops the run.
    if "system" in request or not isinstance(messages, list) or len(cast(list[object], messages)) != 1:
        raise SystemExit(f"{path.name}: admission request is not one user message")
    message = _object(cast(list[object], messages)[0])
    text = message.get("text") if message is not None else None
    if message is None or message.get("role") != "user" or not isinstance(text, str):
        raise SystemExit(f"{path.name}: admission request is not one user message")
    return AnsweredAdmission(digest, hashlib.sha256(raw).hexdigest(), text, schema, answer, slot)


def answered_admissions(base: Path) -> list[AnsweredAdmission]:
    found = (read_record(p) for p in sorted(store_dir(base).glob("*/*.json")))
    return sorted((r for r in found if r is not None), key=lambda r: r.digest)


def manifest_of(records: list[AnsweredAdmission], created_at: str) -> JsonObject:
    return {"schema": MANIFEST_SCHEMA, "declaration": DECLARATION, "output": OUTPUT, "created_at": created_at,
            "selection": "every record whose final.status is answered with an object output",
            "items": [{"digest": r.digest, "sha256": r.sha256} for r in records]}


def records_for(manifest_path: Path, base: Path) -> list[AnsweredAdmission]:
    """The manifest's records, in manifest order. A missing or changed record stops the run."""
    manifest = _object(json.loads(manifest_path.read_text(encoding="utf-8")))
    items = manifest.get("items") if manifest is not None and manifest.get("schema") == MANIFEST_SCHEMA else None
    if not isinstance(items, list):
        raise SystemExit(f"{manifest_path}: not an E-real manifest")
    by_digest = {r.digest: r for r in answered_admissions(base)}
    out: list[AnsweredAdmission] = []
    for item in cast(list[object], items):
        entry = _object(item)
        digest, sha = (entry.get("digest"), entry.get("sha256")) if entry is not None else (None, None)
        record = by_digest.get(digest) if isinstance(digest, str) else None
        if record is None or record.sha256 != sha:
            raise SystemExit(f"{manifest_path}: record {digest!r} is missing or changed")
        out.append(record)
    return out
