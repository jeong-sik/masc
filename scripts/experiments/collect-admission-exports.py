#!/usr/bin/env python3
"""Recover and verify exact synthetic request exports from a verbose CI log."""
import argparse
import hashlib
import json
from pathlib import Path


def top_level_raw_fields(text):
    """Keep original JSON number spellings when checking OCaml wire hashes."""
    decoder = json.JSONDecoder()
    fields = {}
    pos = 1
    if not text.startswith("{"):
        raise ValueError("export must be an object")
    while True:
        while text[pos].isspace():
            pos += 1
        if text[pos] == "}":
            if text[pos + 1:].strip():
                raise ValueError("trailing export bytes")
            return fields
        key, pos = decoder.raw_decode(text, pos)
        if not isinstance(key, str) or key in fields:
            raise ValueError("invalid or duplicate export key")
        while text[pos].isspace():
            pos += 1
        if text[pos] != ":":
            raise ValueError("missing field separator")
        pos += 1
        while text[pos].isspace():
            pos += 1
        start = pos
        _, pos = decoder.raw_decode(text, pos)
        fields[key] = text[start:pos]
        while text[pos].isspace():
            pos += 1
        if text[pos] == ",":
            pos += 1
        elif text[pos] != "}":
            raise ValueError("invalid object separator")


def sha256(text):
    return hashlib.sha256(text.encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("out", type=Path)
    args = parser.parse_args()
    expected = {f"{kind}_{count}" for kind in ("repeated", "independent")
                for count in (1, 30, 200)} | {"verified_replacement", "unresolved_event"}
    exports = {}
    for line in args.log.read_text().splitlines():
        if "MEMORY_ADMISSION_EXPORT " not in line:
            continue
        raw = line.split("MEMORY_ADMISSION_EXPORT ", 1)[1]
        value = json.loads(raw)
        raw_fields = top_level_raw_fields(raw)
        cohort = value["cohort"]
        if cohort not in expected or cohort in exports:
            raise ValueError(f"unexpected or duplicate cohort: {cohort}")
        if value["semantic_judgment_performed"] is not False:
            raise ValueError("capture unexpectedly claims semantic judgment")
        for field in ("prompt", "system_prompt", "keeper_instructions"):
            if sha256(value[field]) != value["input_hashes"][field + "_sha256"]:
                raise ValueError(f"{cohort}: {field} hash mismatch")
        for field in ("schema", "candidates", "initial_current_facts", "scenario_input"):
            if sha256(raw_fields[field]) != value["input_hashes"][field + "_sha256"]:
                raise ValueError(f"{cohort}: {field} wire hash mismatch")
        if sha256(raw_fields["candidates"]) != value["range"]["input_sha256"]:
            raise ValueError(f"{cohort}: consumed-input digest mismatch")
        exports[cohort] = raw
    if set(exports) != expected:
        raise ValueError(f"missing cohorts: {sorted(expected - set(exports))}")
    args.out.mkdir(parents=True, exist_ok=True)
    for cohort, raw in exports.items():
        target = args.out / (cohort + ".json")
        content = raw + "\n"
        if target.exists() and target.read_text() != content:
            raise ValueError(f"refusing to replace a different export: {target}")
        target.write_text(content)
    print(json.dumps({"verified_exports": len(exports), "cohorts": sorted(exports)}))


if __name__ == "__main__":
    main()
