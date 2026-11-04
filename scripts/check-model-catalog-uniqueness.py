#!/usr/bin/env python3
"""Reject duplicate catalog keys the way Model_catalog.reject_duplicate_rows does.

The catalog load contract lives in
packages/agent_core/lib/llm_provider/model_catalog.ml: the same provider id,
or the same (provider_name, model_id) pair, may not be declared twice — a
duplicate makes the whole catalog fail to load and takes the server down with
it (2026-11-04 opencode_go duplicate, repaired in #48151).  This script reads
the TOML bytes directly and mirrors that rule so the contradiction is caught
on a pull request instead of at server boot:

  model key    = (provider_name lowercased+trimmed or None, model_id lowercased)
  provider key = id lowercased+trimmed

Models are checked first, then providers, and the first duplicate is reported
as "model catalog declares <label> twice" — the same order and wording the
loader uses.  Exit 0 when every file is unique, 1 on the first duplicate or
an unreadable file.
"""

import sys

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    import tomli as tomllib  # type: ignore


def normalize_label(value):
    """Model_catalog.normalize_label: String.lowercase_ascii (String.trim value)."""
    return str(value).strip().lower()


def first_duplicate(pairs):
    seen = set()
    for key, label in pairs:
        if key in seen:
            return label
        seen.add(key)
    return None


def check(path):
    with open(path, "rb") as handle:
        catalog = tomllib.load(handle)

    model_pairs = []
    for index, entry in enumerate(catalog.get("models", [])):
        raw_id = entry.get("model_id")
        if raw_id is None:
            return f"{path}: model row {index + 1} has no model_id"
        model_id = str(raw_id)
        provider = entry.get("provider_name")
        provider_key = normalize_label(provider) if provider is not None else None
        key = (provider_key, model_id.lower())
        if provider is None:
            label = f'model row "{model_id}"'
        else:
            label = f'model row "{model_id}" for provider "{provider}"'
        model_pairs.append((key, label))

    duplicate = first_duplicate(model_pairs)
    if duplicate is not None:
        return f"model catalog declares {duplicate} twice"

    provider_pairs = []
    for index, entry in enumerate(catalog.get("providers", [])):
        raw_id = entry.get("id")
        if raw_id is None:
            return f"{path}: provider row {index + 1} has no id"
        provider_id = str(raw_id)
        key = normalize_label(provider_id)
        provider_pairs.append((key, f'provider row "{provider_id}"'))

    duplicate = first_duplicate(provider_pairs)
    if duplicate is not None:
        return f"model catalog declares {duplicate} twice"

    return None


def main(argv):
    paths = argv[1:] or ["packages/agent_core/models.toml"]
    failures = 0
    for path in paths:
        try:
            failure = check(path)
        except (OSError, tomllib.TOMLDecodeError) as error:
            failures += 1
            print(f"{path}: unreadable catalog ({error})")
            continue
        if failure is None:
            print(f"ok: {path}")
        else:
            failures += 1
            print(failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
