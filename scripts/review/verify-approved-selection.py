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
    # A refusal that only says invalid_selection hides which compared field
    # moved between prepare time and verify time; name the field and both
    # values so the dispatch series can be corrected without re-running
    # blind (task-2235 proof dispatches 38112487273..38114237842).
    mismatch = [f"{key}: receipt={receipt.get(key)} computed={current[key]}"
                for key in ("base", "candidate", "tree")
                if receipt.get(key) != current[key]]
    if mismatch:
        raise P.Rejected(P.Reason.INVALID_SELECTION, details=tuple(mismatch))
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
        refused = json.dumps({"status": "refused", "reason": str(error)})
        # The caller redirects stdout to a file, so also echo the refusal to
        # stderr: a hidden refusal costs more debugging time than the extra
        # line is worth.
        print(refused, file=sys.stderr)
        print(refused)
        return 2
    except (OSError, ValueError, KeyError, TypeError, AttributeError,
            P.SourceUnavailable) as error:
        # The reason alone (run 39404586810: "evidence_read_failed") left the
        # dispatch series correcting blind; carry the underlying diagnostic.
        detail = P.unavailable_payload(error)["reason"]
        print(json.dumps({"status": "unavailable", "reason": detail}), file=sys.stderr)
        print(json.dumps({"status": "unavailable", "reason": detail}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
