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
