(** Field-ownership merges for keeper_meta on CAS retry. *)

type t = latest:Keeper_meta_contract.keeper_meta -> caller:Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta

val caller_wins : t
(** Take every field from the caller except [meta_version], which
    follows the disk version. *)

val monotonic_usage_counters : t
(** {!caller_wins}, except cumulative usage counters (total_turns,
    total_*_tokens, total_cost_usd) take [max latest caller] so a CAS
    retry from a stale snapshot can never rewind them (RFC-0225 §3.2).
    last_* observation fields stay with the caller. *)

val heartbeat_fields_from_disk : t
(** {!monotonic_usage_counters}, plus preservation of an operator-owned pause
    already present on disk. This prevents stale turn/heartbeat writers from
    clearing [paused=true] after an operator paused the keeper. *)

val operator_control_fields_from_caller : t
(** {!monotonic_usage_counters}, with the operator-control cluster
    ([paused], [latched_reason], [auto_resume_after_sec], and
    [runtime.last_blocker]) owned by the caller. Used by an explicit current
    operator directive, whose pause/resume decision must win a CAS retry. *)

val non_operator_control_fields_from_disk : t
(** {!monotonic_usage_counters}, with the operator-control cluster always
    preserved from the latest disk snapshot. Use for heartbeat/bootstrap
    writers that own runtime observations but must never pause, resume, clear a
    typed gate, or replace a newer blocker during a CAS retry. *)

val identity_repair_fields_from_caller : t
(** Preserve the latest disk snapshot except for the caller-owned keeper
    identity fields ([agent_name], trace id/history/generation, and update
    timestamp). Usage counters remain monotonic. This prevents a stale identity
    repair from replacing a concurrent operator/continue/repository/Dead gate. *)

val dead_tombstone_cleanup_from_disk : t
(** {!monotonic_usage_counters}, with [paused] and [latched_reason] owned by the
    caller. Used by the dead-tombstone cleanup so a CAS retry that re-reads an
    operator pause cannot copy the operator reason back over [Dead_tombstone].
    The inverse of {!heartbeat_fields_from_disk}, which lets a disk operator
    pause win. *)
