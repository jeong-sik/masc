#!/usr/bin/env python3
"""Parse one immutable ROLL input block from a pull request body."""
import argparse
import hashlib
import json
from pathlib import Path
import re

BLOCK = re.compile(r"<!-- masc-roll-input-v1\s*\n(.*?)\n-->", re.DOTALL)
SHA = re.compile(r"[0-9a-f]{40}\Z")


def _unique_pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate roll input key")
        value[key] = item
    return value


def parse_body(body: str) -> dict:
    if not isinstance(body, str):
        raise ValueError("ROLL body is missing")
    blocks = BLOCK.findall(body)
    if len(blocks) != 1 or body.count("masc-roll-input-v1") != 1:
        raise ValueError("exactly one masc-roll-input-v1 block is required")
    try:
        source = json.loads(blocks[0], object_pairs_hook=_unique_pairs)
    except (json.JSONDecodeError, TypeError) as error:
        raise ValueError("invalid ROLL input JSON") from error
    if not isinstance(source, dict) or set(source) != {"base", "members"}:
        raise ValueError("ROLL input needs only base and members")
    base, members = source["base"], source["members"]
    if not isinstance(base, str) or not SHA.fullmatch(base):
        raise ValueError("invalid ROLL base")
    if not isinstance(members, list) or not members:
        raise ValueError("ROLL members must be a nonempty list")
    seen = set()
    normalized = []
    for member in members:
        if not isinstance(member, dict) or set(member) != {"pr", "head", "review_base"}:
            raise ValueError("invalid ROLL member fields")
        pr, head, review_base = member["pr"], member["head"], member["review_base"]
        if (type(pr) is not int or pr <= 0 or pr in seen
                or not isinstance(head, str) or not SHA.fullmatch(head)
                or not isinstance(review_base, str) or not SHA.fullmatch(review_base)):
            raise ValueError("invalid ROLL member identity")
        seen.add(pr)
        normalized.append({"pr": pr, "head": head, "review_base": review_base})
    core = {"base": base, "members": normalized}
    digest = hashlib.sha256(json.dumps(
        core, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")).hexdigest()
    return {"schema": "masc.roll.input.v1", **core, "digest": "sha256:" + digest}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--body-file", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(parse_body(args.body_file.read_text()), sort_keys=True))
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
