# pyright: strict
"""Read answered keeper-librarian admission records from the exact-request store.

The store is <base>/.masc/lane-addons/exact-requests/<scope>/<digest>.json and
belongs to the running server. A record holds the request MASC sent (one user
message and the output JSON Schema) and, once a slot answered, the accepted
answer in `final.output`.

The server moves an admission's originals out of its store and removes their
text once every candidate is committed and acknowledged (#50732). `snapshot`
therefore copies the answered records, byte for byte, into a store of the same
shape under another base, and E-real runs read that copy. This module never
writes the server's store.

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

import yojson_wire as W

DECLARATION = "keeper-librarian"
OUTPUT = "admission"
MANIFEST_SCHEMA = "masc.tinker.librarian.e_real_manifest.v1"

type JsonDict = dict[str, object]  # the manifest, which this module writes


@dataclass(frozen=True, slots=True)
class AnsweredAdmission:
    digest: str
    sha256: str
    prompt: str  # the one user message MASC sent
    schema: W.JsonObject  # the output JSON Schema MASC sent
    answer: W.JsonObject  # the answer MASC accepted
    slot: str  # the slot that answered


def base_path(arg: str | None) -> Path:
    raw = arg or os.environ.get("MASC_BASE_PATH")
    if not raw:
        raise SystemExit("pass --base or set MASC_BASE_PATH")
    return Path(raw).expanduser()


def store_dir(base: Path) -> Path:
    return base / ".masc" / "lane-addons" / "exact-requests"


def _object(value: object) -> JsonDict | None:
    return cast(JsonDict, value) if isinstance(value, dict) else None


def read_json(raw: bytes) -> W.Json | None:
    """A record MASC wrote with `Yojson.Safe.to_string`, read as MASC reads it, or None.

    The Yojson port keeps an out-of-range integer as Intlit text and reads any
    depth; json.loads stops past 4300 digits or near 1000 levels. Yojson stores
    a lone surrogate escape as the bytes ED B0 80, and surrogatepass reads them
    back as that one code point. None: the bytes do not decode that way, or
    the text is not JSON.
    """
    try:
        text = raw.decode("utf-8", "surrogatepass")
    except UnicodeDecodeError:
        return None
    value = W.parse(text)
    return None if isinstance(value, W.JsonError) else value


def read_record(path: Path) -> AnsweredAdmission | None:
    return record_of(path.read_bytes(), path.name)


def record_of(raw: bytes, name: str) -> AnsweredAdmission | None:
    """The record file `name` holding `raw` when it is an answered admission of keeper-librarian,
    else None. A record that cannot be read stops the run."""
    rec = read_json(raw)
    if rec is None:
        raise SystemExit(f"{name}: not a JSON record")
    if not isinstance(rec, W.JsonObject) or W.member(rec, "declaration_id") != DECLARATION:
        return None
    request, final = W.member(rec, "request"), W.member(rec, "final")
    if (not isinstance(request, W.JsonObject) or not isinstance(final, W.JsonObject)
            or W.member(request, "output") != OUTPUT or W.member(final, "status") != "answered"):
        return None
    schema, answer, messages = W.member(request, "schema"), W.member(final, "output"), W.member(request, "messages")
    digest, slot = W.member(rec, "digest"), W.member(final, "slot")
    if (not isinstance(schema, W.JsonObject) or not isinstance(answer, W.JsonObject)
            or not isinstance(digest, str) or not isinstance(slot, str)):
        return None
    # Every admission request so far is one user message without a system field.
    # Another shape would reach the wire differently, so it stops the run.
    if not isinstance(W.member(request, "system"), W.Absent) or not isinstance(messages, tuple) or len(messages) != 1:
        raise SystemExit(f"{name}: admission request is not one user message")
    message = messages[0]
    if not isinstance(message, W.JsonObject):
        raise SystemExit(f"{name}: admission request is not one user message")
    text = W.member(message, "text")
    if W.member(message, "role") != "user" or not isinstance(text, str):
        raise SystemExit(f"{name}: admission request is not one user message")
    return AnsweredAdmission(digest, hashlib.sha256(raw).hexdigest(), text, schema, answer, slot)


def answered_admissions(base: Path) -> list[AnsweredAdmission]:
    found = (read_record(p) for p in sorted(store_dir(base).glob("*/*.json")))
    return sorted((r for r in found if r is not None), key=lambda r: r.digest)


def snapshot(live: Path, base: Path) -> list[AnsweredAdmission]:
    """Copy each answered admission record of `live`'s store into `base`'s store, the bytes it was
    read with under the same scope and name, and return the copies as `answered_admissions(base)`
    reads them. Other records are not copied. `base` is readable by its owner alone: the copies
    hold Keeper memory. SystemExit when `base`'s store already holds a record, since a manifest
    pins the records of one snapshot."""
    target = store_dir(base)
    if any(target.glob("*/*.json")):
        raise SystemExit(f"{target} already holds records")
    base.mkdir(parents=True, exist_ok=True)
    base.chmod(0o700)
    for path in sorted(store_dir(live).glob("*/*.json")):
        raw = path.read_bytes()
        if record_of(raw, path.name) is None:
            continue
        copy = target / path.parent.name / path.name
        copy.parent.mkdir(parents=True, exist_ok=True)
        copy.write_bytes(raw)
    return answered_admissions(base)


def manifest_of(records: list[AnsweredAdmission], created_at: str) -> JsonDict:
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
