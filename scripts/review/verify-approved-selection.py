#!/usr/bin/env python3
"""Recheck source approvals and the exact combined candidate before chosen CI."""
import argparse
import importlib.util
import json
from pathlib import Path
import os
import sys


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    loaded = importlib.util.module_from_spec(spec)
    sys.modules[name] = loaded
    spec.loader.exec_module(loaded)
    return loaded


P = module("prepare_approved_selection", "prepare-approved-batch.py")


def verify(receipt, *, repo, candidate, git_dir, gh, prepare=P.prepare):
    if (receipt.get("schema_version") != 1 or receipt.get("status") != "prepared"
            or receipt.get("repo") != repo or receipt.get("candidate") != candidate):
        raise P.Rejected(P.Reason.INVALID_SELECTION)
    selected = tuple(P.member(str(m["pr"]) + "@" + m["head"]) for m in receipt["members"])
    current = prepare(P, repo=repo, leader=receipt["leader"], selected=selected,
                      git_dir=git_dir, gh=gh)
    if any(receipt.get(key) != current[key] for key in ("base", "candidate", "tree")):
        raise P.Rejected(P.Reason.INVALID_SELECTION)
    for previous, live in zip(receipt["members"], current["members"]):
        ids = previous["approval_ids"]
        if (not isinstance(ids, list) or not ids
                or any(type(i) is not int or i <= 0 for i in ids)
                or not set(ids).issubset(live["approval_ids"])):
            raise P.Rejected(P.Reason.APPROVAL_CHANGED)
    return current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("selection", "repo", "candidate", "git-dir"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        receipt = json.loads(Path(args.selection).read_text())
        verified = verify(receipt, repo=args.repo, candidate=args.candidate,
                          git_dir=args.git_dir, gh=os.environ.get("GUARD_GH", "gh"))
        print(json.dumps(verified, sort_keys=True))
        return 0
    except (P.Rejected, argparse.ArgumentTypeError) as error:
        print(json.dumps({"status": "refused", "reason": str(error)}))
        return 2
    except (OSError, ValueError, KeyError, TypeError, AttributeError, P.SourceUnavailable):
        print(json.dumps({"status": "unavailable", "reason": "evidence_read_failed"}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
