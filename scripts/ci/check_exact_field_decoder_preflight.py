#!/usr/bin/env python3
"""Every exact-field decoder is either read by the deploy preflight or
declared to hold no files.

Three landings in one month removed a field and left durable rows behind
(#29628, #29277, #29666). Each time the rows were written by a decoder that
demands an exact field set, and nothing read that store with the production
decoder before the binary shipped.

What decides the risk is not which directory a store lives in. It is whether
the decoder refuses a row for carrying a field the new binary does not know.
So this walks the decoders, not the directories: a module that calls
`exact_object_fields` or `fields_are_unique_known` must appear in the
preflight's `durable_stores`, or be listed below with the reason it holds no
files. A new one that is neither fails here rather than in production.
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
PREFLIGHT = REPO / "bin" / "deployment_preflight_helper.ml"
# Two spellings of the same contract. Some modules call the shared helper;
# others enforce it with a closed match whose fallback says so. Scanning only
# the helper name found 3 of the 7 modules that actually refuse unknown
# fields, so the message is part of the signal.
EXACT_FIELD_CALLS = ("exact_object_fields", "fields_are_unique_known")
EXACT_FIELD_MESSAGES = ("fields are not exact",)

# Decoders whose input is a request body or an in-memory value, never a file.
# A field removal cannot strand rows for these: there are no rows.
NO_DURABLE_STORE = {
    "keeper_multimodal_input": "decodes chat/vision request bodies",
    "keeper_paused_work_operator_request": "decodes an operator request payload",
}


def modules_with_exact_field_decoders() -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for path in sorted((REPO / "lib").rglob("*.ml")):
        text = path.read_text(encoding="utf-8", errors="replace")
        hits = [call for call in EXACT_FIELD_CALLS if re.search(rf"\b{call}\b", text)]
        hits += [msg for msg in EXACT_FIELD_MESSAGES if msg in text]
        if hits:
            found[path.stem] = hits
    return found


def preflight_decoder_calls() -> str:
    """The preflight file with comments stripped.

    Matching a module name anywhere in the file passes on a mention in a
    comment, which is how a store removed from `durable_stores` still read as
    covered. Matching only inside the `durable_stores` records goes too far
    the other way: the event queue is validated through a `~load:` argument
    above that list, and it is genuinely covered. What both get wrong is
    counting prose as code, so the prose is removed and every remaining
    reference is a real call.
    """
    if not PREFLIGHT.exists():
        sys.exit(f"FAIL: {PREFLIGHT.relative_to(REPO)} is missing")
    text = PREFLIGHT.read_text(encoding="utf-8", errors="replace")
    stripped: list[str] = []
    depth = 0
    index = 0
    while index < len(text):
        if text.startswith("(*", index):
            depth += 1
            index += 2
        elif text.startswith("*)", index) and depth:
            depth -= 1
            index += 2
        else:
            if not depth:
                stripped.append(text[index])
            index += 1
    return "".join(stripped)


def main() -> int:
    print("=== exact-field decoder preflight coverage ===")
    preflight = preflight_decoder_calls()
    decoders = modules_with_exact_field_decoders()
    if not decoders:
        print("FAIL: no exact-field decoders found; the scan lost its subject")
        return 1

    unregistered: list[str] = []
    for module in sorted(decoders):
        module_ref = module[:1].upper() + module[1:]
        if re.search(rf"\b{re.escape(module_ref)}\b", preflight):
            state = "preflight"
        elif module in NO_DURABLE_STORE:
            state = f"no store — {NO_DURABLE_STORE[module]}"
        else:
            state = "UNREGISTERED"
            unregistered.append(module)
        print(f"  {module:<48s} {state}")

    if unregistered:
        print()
        print("FAIL: these decoders refuse rows that carry an unknown field, and")
        print("      nothing reads their store before a deploy:")
        for module in unregistered:
            print(f"        {module}")
        print()
        print("      Add a store to durable_stores in")
        print("      bin/deployment_preflight_helper.ml that reads it with this")
        print("      same decoder, or add it to NO_DURABLE_STORE in this script")
        print("      with the reason it holds no files.")
        return 1

    print()
    print(
        f"PASS: {len(decoders)} exact-field decoder(s); "
        f"{len(decoders) - len(NO_DURABLE_STORE & decoders.keys())} read by the preflight, "
        f"{len(NO_DURABLE_STORE & decoders.keys())} declared file-free."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
