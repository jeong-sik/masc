"""The keeper-memory-health answer the TUI decodes, for the TUI tests that
serve it. A test changes only the fields it reads, so a field the server adds
to a row is written here once. The TUI refuses a row whose fields are not
exactly these."""

SCHEMA = "keeper.memory_os.current_health.v17"

# Every pass and change the server counts, none moved since it started.
NO_MEMORY_CHANGES: dict[str, dict[str, int]] = {
    commit_pass: {change: 0 for change in ("added", "absorbed", "superseded", "dropped")}
    for commit_pass in (
        "admission", "durable", "continuity", "cleanup", "keeper_write", "keeper_delete", "operator_delete",
    )
}

TOTAL_NAMES: tuple[str, ...] = (
    "facts",
    "observed_facts",
    "derived_facts",
    "support_invalidations",
    "snapshot_bytes",
    "added",
    "removed",
    "source_facts",
    "source_invalidations",
    "source_snapshot_bytes",
    "librarian_unread_turns",
    "librarian_continuity_unread_atoms",
    "librarian_continuity_unmeasured",
    "librarian_failures",
    "vision_ingest_errors",
    "read_errors",
    "source_read_errors",
)

ALERT_SUMMARY_NAMES: tuple[str, ...] = (
    "total_alerts",
    "warn_alerts",
    "error_alerts",
    "keepers_with_alerts",
    "snapshot_read_error_keepers",
    "source_snapshot_read_error_keepers",
    "librarian_stopped_keepers",
    "librarian_attention_required_keepers",
    "librarian_starving_keepers",
)


def keeper_row(keeper_id: str, **fields: object) -> dict[str, object]:
    """The Keeper's row with nothing in it and no alert, then [fields]. A
    field the row does not have is refused here rather than by the TUI."""
    available = {"kind": "available", "messages": []}
    row: dict[str, object] = {
        "keeper_id": keeper_id,
        "revision": 0,
        "updated_at": None,
        "facts": 0,
        "observed_facts": 0,
        "derived_facts": 0,
        "support_invalidations": 0,
        "snapshot_bytes": 0,
        "added": 0,
        "removed": 0,
        "snapshot_present": False,
        "age_bins": None,
        "facts_by_hour": [],
        "changes_since_start": NO_MEMORY_CHANGES,
        "context_cycle": {
            "saved": None,
            "saved_read_error": None,
            "read_position": None,
            "read_position_read_error": None,
            "rewriting_through": None,
            "prepared": None,
            "synthesis": None,
            "unread": {"snapshot": available, "memory": available},
        },
        "librarian": {
            "state": "drained",
            "detail": None,
            "pending": None,
            "admission_wait": None,
            "operator_action_required": False,
            "measured_at": 1.0,
            "unread_atom_turns": 0,
            "unread_official_turns": 0,
            "continuity_unread_atoms": 0,
            "last_success_at": None,
            "last_failure_kind": None,
            "stalled": None,
        },
        # A Keeper outside the registry: no Memory writer is made for it.
        "writer": {"kind": "no_writer"},
        "librarian_failures": 0,
        "vision_ingest_errors": 0,
        "vision_ingest_error_reasons": [],
        "read_error": None,
        "source_revision": 0,
        "source_facts": 0,
        "source_invalidations": 0,
        "source_snapshot_bytes": 0,
        "source_snapshot_present": False,
        "source_read_error": None,
        "alerts": [],
    }
    unknown = sorted(set(fields) - set(row))
    if unknown:
        raise KeyError(f"a keeper-memory-health row has no field {unknown}")
    return {**row, **fields}


def fleet(
    keepers: list[dict[str, object]],
    *,
    execution: dict[str, object],
    totals: dict[str, int],
) -> dict[str, object]:
    """The fleet answer listing [keepers], with every total zero but [totals]
    and no alert."""
    unknown = sorted(set(totals) - set(TOTAL_NAMES))
    if unknown:
        raise KeyError(f"the fleet has no total {unknown}")
    return {
        "schema": SCHEMA,
        "generated_at": 1.0,
        "execution": execution,
        "keepers": keepers,
        "totals": {name: totals.get(name, 0) for name in TOTAL_NAMES},
        "alert_summary": {name: 0 for name in ALERT_SUMMARY_NAMES},
    }
