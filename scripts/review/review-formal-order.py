#!/usr/bin/env python3
"""Order formal GitHub reviews by submission, refusing an ambiguous latest review.

Reads one review object per line and prints account, ID and state as TSV. Review
IDs identify records, but their creation order is not their submission order.
"""
import importlib.util
import json
from pathlib import Path
import sys


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("review_decisions_order", HERE / "review-decisions.py")
decisions = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = decisions
spec.loader.exec_module(decisions)

FORMAL = frozenset(("APPROVED", "CHANGES_REQUESTED", "DISMISSED"))


def ordered_rows(records):
    rows = []
    seen = set()
    account_ids = {}
    account_logins = {}
    for record in records:
        if not isinstance(record, dict) or record.get("state") not in FORMAL:
            raise ValueError("invalid formal review record")
        actor = decisions.actor_login(record)
        rid = record.get("id")
        if actor is None or type(rid) is not int or rid < 1 or rid in seen:
            raise ValueError("formal review has missing account or invalid ID")
        seen.add(rid)
        when = decisions.timestamp(record.get("submitted_at"), "submitted_at")
        key = actor.casefold()
        user_id = record["user"].get("id")
        if type(user_id) is int and user_id > 0:
            if key in account_ids and account_ids[key] != user_id:
                raise ValueError(f"formal reviews by {actor} have conflicting account IDs")
            if user_id in account_logins and account_logins[user_id] != key:
                raise ValueError(f"formal review account {user_id} has conflicting logins")
            account_ids[key] = user_id
            account_logins[user_id] = key
        rows.append((key, actor, rid, record["state"], when))
    # Stable sorts put each account's newest published formal review first.
    rows.sort(key=lambda row: row[4], reverse=True)
    rows.sort(key=lambda row: row[0])
    # Older ties cannot change the latest formal state. Request replacement is
    # checked separately by ID and requires a strictly later submission time.
    last_actor = canonical_actor = None
    latest_when = None
    ordered = []
    for key, actor, rid, state, when in rows:
        if key != last_actor:
            last_actor, canonical_actor, latest_when = key, actor, when
        elif when == latest_when:
            raise ValueError(f"formal reviews by {actor} have ambiguous submission times")
        ordered.append((canonical_actor, rid, state))
    return ordered


def latest_reviews(records):
    """Return each account's latest formal record under the guard's ordering."""
    rows = ordered_rows(records)
    by_id = {record["id"]: record for record in records}
    latest = {}
    for actor, rid, _ in rows:
        latest.setdefault(actor, by_id[rid])
    return latest


def main():
    try:
        records = [json.loads(line) for line in sys.stdin if line.strip()]
        for actor, rid, state in ordered_rows(records):
            print(f"{actor}\t{rid}\t{state}")
    except (ValueError, TypeError) as error:
        print(f"review-formal-order: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
