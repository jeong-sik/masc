"""Tests for the RFC-0203 Phase 2 traffic audit (sidecar side).

These tests pin the JSONL shape to match
``lib/gate/discord_dual_run_stats.ml`` 1:1 so the dual-run cross-path
diff stays meaningful as both sides evolve.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from src.traffic_audit import (
    Counts,
    ErrMissingToken,
    ErrRuntime,
    ErrTransient,
    ErrWorkflow,
    OkMessageId,
    TrafficAuditStore,
)
from src.traffic_audit_path import (
    AUDIT_PATH_ENV,
    DEFAULT_AUDIT_PATH,
    resolve_audit_path,
)


# ---------------------------------------------------------------- #
# Counters                                                         #
# ---------------------------------------------------------------- #


def test_zero_init(tmp_path: Path) -> None:
    store = TrafficAuditStore(tmp_path / "audit.jsonl")
    assert store.snapshot(path="sidecar") == Counts()
    assert store.snapshot(path="builtin") == Counts()


def test_inbound_per_kind_buckets(tmp_path: Path) -> None:
    store = TrafficAuditStore(tmp_path / "audit.jsonl")
    store.record_inbound(path="sidecar", kind="ready")
    store.record_inbound(path="sidecar", kind="message_create")
    store.record_inbound(path="sidecar", kind="message_create")
    store.record_inbound(path="sidecar", kind="reaction_add")
    store.record_inbound(path="sidecar", kind="ignored")
    snap = store.snapshot(path="sidecar")
    assert snap.ready == 1
    assert snap.message_create == 2
    assert snap.reaction_add == 1
    assert snap.ignored == 1


def test_per_path_isolation(tmp_path: Path) -> None:
    store = TrafficAuditStore(tmp_path / "audit.jsonl")
    store.record_inbound(path="sidecar", kind="message_create")
    store.record_inbound(path="builtin", kind="message_create")
    store.record_inbound(path="builtin", kind="message_create")
    assert store.snapshot(path="sidecar").message_create == 1
    assert store.snapshot(path="builtin").message_create == 2


def test_outbound_each_variant(tmp_path: Path) -> None:
    store = TrafficAuditStore(tmp_path / "audit.jsonl")
    store.record_outbound(path="sidecar", outcome=OkMessageId("123"))
    store.record_outbound(path="sidecar", outcome=ErrMissingToken())
    store.record_outbound(path="sidecar", outcome=ErrTransient("503"))
    store.record_outbound(path="sidecar", outcome=ErrWorkflow("404"))
    store.record_outbound(path="sidecar", outcome=ErrRuntime("oops"))
    snap = store.snapshot(path="sidecar")
    assert snap.outbound_ok == 1
    assert snap.outbound_err_missing_token == 1
    assert snap.outbound_err_transient == 1
    assert snap.outbound_err_workflow == 1
    assert snap.outbound_err_runtime == 1


def test_reset_for_test_zeros_counts(tmp_path: Path) -> None:
    store = TrafficAuditStore(tmp_path / "audit.jsonl")
    store.record_inbound(path="sidecar", kind="ready")
    store.record_inbound(path="builtin", kind="message_create")
    store.reset_for_test()
    assert store.snapshot(path="sidecar") == Counts()
    assert store.snapshot(path="builtin") == Counts()


# ---------------------------------------------------------------- #
# JSONL shape                                                      #
# ---------------------------------------------------------------- #


def _read_lines(path: Path) -> list[dict[str, str]]:
    return [json.loads(line) for line in path.read_text().splitlines()]


def test_inbound_jsonl_shape(tmp_path: Path) -> None:
    audit = tmp_path / "audit.jsonl"
    store = TrafficAuditStore(audit)
    store.record_inbound(path="sidecar", kind="message_create")
    rows = _read_lines(audit)
    assert len(rows) == 1
    row = rows[0]
    assert row["direction"] == "inbound"
    assert row["path"] == "sidecar"
    assert row["kind"] == "message_create"
    assert "timestamp" in row
    # Inbound has no extra fields beyond the four core ones.
    assert set(row.keys()) == {"timestamp", "direction", "path", "kind"}


def test_outbound_ok_carries_message_id(tmp_path: Path) -> None:
    audit = tmp_path / "audit.jsonl"
    store = TrafficAuditStore(audit)
    store.record_outbound(path="sidecar", outcome=OkMessageId("987654321"))
    row = _read_lines(audit)[0]
    assert row["direction"] == "outbound"
    assert row["outcome"] == "ok"
    assert row["message_id"] == "987654321"
    assert "message" not in row


def test_outbound_missing_token_has_no_payload_field(tmp_path: Path) -> None:
    audit = tmp_path / "audit.jsonl"
    store = TrafficAuditStore(audit)
    store.record_outbound(path="sidecar", outcome=ErrMissingToken())
    row = _read_lines(audit)[0]
    assert row["outcome"] == "err_missing_token"
    assert "message" not in row
    assert "message_id" not in row


@pytest.mark.parametrize(
    ("outcome", "expected_outcome_str"),
    [
        (ErrTransient("503 upstream"), "err_transient"),
        (ErrWorkflow("channel not found"), "err_workflow"),
        (ErrRuntime("unhandled"), "err_runtime"),
    ],
)
def test_outbound_err_variants_carry_message(
    tmp_path: Path, outcome: object, expected_outcome_str: str
) -> None:
    audit = tmp_path / "audit.jsonl"
    store = TrafficAuditStore(audit)
    # The cast below is intentional: pytest.mark.parametrize loses the
    # union type, but each row is one of the OutboundOutcome variants.
    store.record_outbound(path="sidecar", outcome=outcome)  # type: ignore[arg-type]
    row = _read_lines(audit)[0]
    assert row["outcome"] == expected_outcome_str
    # All err_* variants except missing_token carry "message".
    assert "message" in row


def test_multi_line_append(tmp_path: Path) -> None:
    audit = tmp_path / "audit.jsonl"
    store = TrafficAuditStore(audit)
    store.record_inbound(path="sidecar", kind="ready")
    store.record_inbound(path="builtin", kind="message_create")
    store.record_outbound(path="sidecar", outcome=OkMessageId("1"))
    rows = _read_lines(audit)
    assert len(rows) == 3
    assert [r["path"] for r in rows] == ["sidecar", "builtin", "sidecar"]
    assert [r["direction"] for r in rows] == ["inbound", "inbound", "outbound"]


def test_append_creates_missing_parent_dir(tmp_path: Path) -> None:
    audit = tmp_path / "nested" / "deeper" / "audit.jsonl"
    store = TrafficAuditStore(audit)
    store.record_inbound(path="sidecar", kind="ready")
    assert audit.exists()
    assert len(_read_lines(audit)) == 1


# ---------------------------------------------------------------- #
# Path resolution                                                  #
# ---------------------------------------------------------------- #


def test_resolve_default_when_env_unset(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(AUDIT_PATH_ENV, raising=False)
    assert resolve_audit_path() == Path(DEFAULT_AUDIT_PATH)


def test_resolve_env_override(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(AUDIT_PATH_ENV, "/tmp/custom_audit.jsonl")
    assert resolve_audit_path() == Path("/tmp/custom_audit.jsonl")


def test_resolve_empty_env_falls_back_to_default(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(AUDIT_PATH_ENV, "")
    assert resolve_audit_path() == Path(DEFAULT_AUDIT_PATH)


def test_resolve_whitespace_env_falls_back_to_default(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(AUDIT_PATH_ENV, "   ")
    assert resolve_audit_path() == Path(DEFAULT_AUDIT_PATH)


def test_resolve_env_whitespace_trimmed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(AUDIT_PATH_ENV, "  /tmp/abc.jsonl  ")
    assert resolve_audit_path() == Path("/tmp/abc.jsonl")


def test_default_path_matches_ocaml_constant() -> None:
    # Cross-language SSOT pin: must match
    # lib/gate/discord_dual_run_stats.ml default_audit_path.
    assert DEFAULT_AUDIT_PATH == ".gate/runtime/discord/traffic_audit.jsonl"


def test_env_var_name_matches_ocaml_constant() -> None:
    # Same env var name as OCaml side so a single export controls both.
    assert AUDIT_PATH_ENV == "MASC_DISCORD_TRAFFIC_AUDIT_PATH"


def test_store_uses_resolver_when_path_omitted(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    target = tmp_path / "resolved.jsonl"
    monkeypatch.setenv(AUDIT_PATH_ENV, str(target))
    store = TrafficAuditStore()
    assert store.path == target


# ---------------------------------------------------------------- #
# Best-effort failure mode                                         #
# ---------------------------------------------------------------- #


def test_append_swallows_oserror(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Make .parent.mkdir fail with OSError and verify the store does
    # not propagate: live counters remain correct, file may be missing.
    audit = tmp_path / "audit.jsonl"
    store = TrafficAuditStore(audit)

    def _boom(*args: object, **kwargs: object) -> None:
        raise OSError("simulated disk failure")

    monkeypatch.setattr(Path, "mkdir", _boom)
    # Must not raise.
    store.record_inbound(path="sidecar", kind="ready")
    # Live counter still incremented (load-bearing measurement).
    assert store.snapshot(path="sidecar").ready == 1
    # File was not created.
    assert not audit.exists()
    _ = os  # silence import-not-used lint when monkeypatch handles env
