"""Traffic audit for RFC-0203 Phase 2 dual-run.

Sidecar-side counterpart of the in-process gateway's
[lib/gate/discord_dual_run_stats.ml]. Same JSONL schema, same
default path, same env override — so the two paths can be compared
offline by reading one file.

Schema (mirrors OCaml verbatim):

    inbound:
      {"timestamp": "<ISO8601>", "direction": "inbound",
       "path": "sidecar"|"builtin",
       "kind": "ready"|"message_create"|"reaction_add"|"ignored"}

    outbound:
      {"timestamp": "<ISO8601>", "direction": "outbound",
       "path": "sidecar"|"builtin",
       "outcome": "ok"|"err_missing_token"|"err_transient"
                  |"err_workflow"|"err_runtime",
       "message_id"?: "<snowflake>",       (* outcome=ok only *)
       "message"?: "<detail>"}              (* outcome=err_* with payload *)

Anti-pattern guard (RFC-0088): every variant is a typed dataclass or
typed Literal — no substring matching on outcome strings, no
catch-all wildcard. ``_outcome_string`` and ``_bucket_of_outbound``
both use ``match`` with ``assert_never`` so adding a new outbound
variant is a compile-time forcing function across every call site.
"""

from __future__ import annotations

import json
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal, assert_never

from .traffic_audit_path import resolve_audit_path

# ---------------------------------------------------------------- #
# Closed-sum types                                                 #
# ---------------------------------------------------------------- #

TrafficPath = Literal["sidecar", "builtin"]
InboundKind = Literal["ready", "message_create", "reaction_add", "ignored"]


@dataclass(frozen=True, slots=True)
class OkMessageId:
    message_id: str


@dataclass(frozen=True, slots=True)
class ErrMissingToken:
    pass


@dataclass(frozen=True, slots=True)
class ErrTransient:
    message: str


@dataclass(frozen=True, slots=True)
class ErrWorkflow:
    message: str


@dataclass(frozen=True, slots=True)
class ErrRuntime:
    message: str


OutboundOutcome = (
    OkMessageId | ErrMissingToken | ErrTransient | ErrWorkflow | ErrRuntime
)


@dataclass(frozen=True, slots=True)
class Counts:
    """Snapshot of one path's counters at a moment in time.

    Fields match OCaml ``counts`` record 1:1.
    """

    ready: int = 0
    message_create: int = 0
    reaction_add: int = 0
    ignored: int = 0
    outbound_ok: int = 0
    outbound_err_missing_token: int = 0
    outbound_err_transient: int = 0
    outbound_err_workflow: int = 0
    outbound_err_runtime: int = 0


# ---------------------------------------------------------------- #
# Store                                                            #
# ---------------------------------------------------------------- #


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


_BUCKET_KEYS: tuple[str, ...] = (
    "ready",
    "message_create",
    "reaction_add",
    "ignored",
    "outbound_ok",
    "outbound_err_missing_token",
    "outbound_err_transient",
    "outbound_err_workflow",
    "outbound_err_runtime",
)


def _zero_buckets() -> dict[str, int]:
    return {k: 0 for k in _BUCKET_KEYS}


def _outcome_bucket(outcome: OutboundOutcome) -> str:
    match outcome:
        case OkMessageId():
            return "outbound_ok"
        case ErrMissingToken():
            return "outbound_err_missing_token"
        case ErrTransient():
            return "outbound_err_transient"
        case ErrWorkflow():
            return "outbound_err_workflow"
        case ErrRuntime():
            return "outbound_err_runtime"
        case _:
            assert_never(outcome)


def _outcome_string(outcome: OutboundOutcome) -> str:
    match outcome:
        case OkMessageId():
            return "ok"
        case ErrMissingToken():
            return "err_missing_token"
        case ErrTransient():
            return "err_transient"
        case ErrWorkflow():
            return "err_workflow"
        case ErrRuntime():
            return "err_runtime"
        case _:
            assert_never(outcome)


def _outcome_detail(outcome: OutboundOutcome) -> dict[str, str]:
    match outcome:
        case OkMessageId(message_id=mid):
            return {"message_id": mid}
        case ErrMissingToken():
            return {}
        case ErrTransient(message=m) | ErrWorkflow(message=m) | ErrRuntime(message=m):
            return {"message": m}
        case _:
            assert_never(outcome)


class TrafficAuditStore:
    """Live counters + best-effort JSONL append.

    Counters are the load-bearing measurement. JSONL is for offline
    cross-path diff and is best-effort: an OSError during append is
    swallowed so a temporary disk issue doesn't crash the bot.

    Thread-safe via a single mutex (``threading.Lock``). discord.py's
    event loop is single-threaded so contention is effectively zero,
    but the mutex insulates against any future thread-pool dispatch
    and matches the OCaml side's data-race-free semantics.
    """

    def __init__(self, path: Path | None = None) -> None:
        self._path: Path = path if path is not None else resolve_audit_path()
        self._lock: threading.Lock = threading.Lock()
        self._counts: dict[TrafficPath, dict[str, int]] = {
            "sidecar": _zero_buckets(),
            "builtin": _zero_buckets(),
        }

    @property
    def path(self) -> Path:
        return self._path

    def record_inbound(self, *, path: TrafficPath, kind: InboundKind) -> None:
        with self._lock:
            self._counts[path][kind] += 1
        self._append(
            {
                "timestamp": _utc_now_iso(),
                "direction": "inbound",
                "path": path,
                "kind": kind,
            }
        )

    def record_outbound(
        self, *, path: TrafficPath, outcome: OutboundOutcome
    ) -> None:
        with self._lock:
            self._counts[path][_outcome_bucket(outcome)] += 1
        record: dict[str, str] = {
            "timestamp": _utc_now_iso(),
            "direction": "outbound",
            "path": path,
            "outcome": _outcome_string(outcome),
        }
        record.update(_outcome_detail(outcome))
        self._append(record)

    def snapshot(self, *, path: TrafficPath) -> Counts:
        with self._lock:
            c = self._counts[path]
            return Counts(
                ready=c["ready"],
                message_create=c["message_create"],
                reaction_add=c["reaction_add"],
                ignored=c["ignored"],
                outbound_ok=c["outbound_ok"],
                outbound_err_missing_token=c["outbound_err_missing_token"],
                outbound_err_transient=c["outbound_err_transient"],
                outbound_err_workflow=c["outbound_err_workflow"],
                outbound_err_runtime=c["outbound_err_runtime"],
            )

    def reset_for_test(self) -> None:
        with self._lock:
            self._counts["sidecar"] = _zero_buckets()
            self._counts["builtin"] = _zero_buckets()

    def _append(self, record: dict[str, str]) -> None:
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            with self._path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False))
                f.write("\n")
        except OSError:
            pass
