"""Skill activation event logs for tests, written from a ledger fixture.

The server opens a session's log with a header row naming the workspace and
the session, then appends one row per event (header_to_yojson and
event_to_yojson in Keeper_skill_activation_ledger). ``event_log`` writes rows
that fold to a masc.skill-activations/v5 ledger: the header, every activation
recorded with no delivery and no actions, then each activation's delivery and
actions, then the transition rejections.
"""

import copy
import json
from typing import Any

# The header schema the server's writer puts on row 1.
EVENTS_SCHEMA = "masc.skill-activation-events/v1"
COMPACT = (",", ":")


def header_row(workspace_key: str, session_id: str) -> dict[str, Any]:
    return {
        "schema": EVENTS_SCHEMA,
        "kind": "opened",
        "workspace_key": workspace_key,
        "session_id": session_id,
    }


def recorded_row(activation: dict[str, Any]) -> dict[str, Any]:
    recorded = copy.deepcopy(activation)
    recorded["delivery"] = None
    recorded["actions"] = []
    return {"kind": "activation_recorded", "activation": recorded}


def delivery_row(skill_tool_use_id: str, delivery: dict[str, Any]) -> dict[str, Any]:
    return {
        "kind": "deliveries_observed",
        "deliveries": [{"skill_tool_use_id": skill_tool_use_id, "delivery": delivery}],
    }


def action_row(skill_tool_use_ids: list[str], action: dict[str, Any]) -> dict[str, Any]:
    return {
        "kind": "action_observed",
        "skill_tool_use_ids": skill_tool_use_ids,
        "action": action,
    }


def rejection_row(rejection: dict[str, Any]) -> dict[str, Any]:
    return {"kind": "transition_rejected", "rejection": rejection}


def event_rows(ledger: dict[str, Any]) -> list[dict[str, Any]]:
    rows = [header_row(ledger["workspace_key"], ledger["session_id"])]
    rows.extend(recorded_row(activation) for activation in ledger["activations"])
    for activation in ledger["activations"]:
        skill_tool_use_id = activation["skill_tool_use_id"]
        if activation["delivery"] is not None:
            rows.append(delivery_row(skill_tool_use_id, activation["delivery"]))
        rows.extend(
            action_row([skill_tool_use_id], action) for action in activation["actions"]
        )
    rows.extend(
        rejection_row(rejection) for rejection in ledger["transition_rejections"]
    )
    return rows


def encode_rows(
    rows: list[dict[str, Any]], *, separators: tuple[str, str] = COMPACT
) -> bytes:
    return b"".join(
        (json.dumps(row, ensure_ascii=False, separators=separators) + "\n").encode()
        for row in rows
    )


def event_log(
    ledger: dict[str, Any], *, separators: tuple[str, str] = COMPACT
) -> bytes:
    return encode_rows(event_rows(ledger), separators=separators)
