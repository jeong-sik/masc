(** Single source of truth for Keeper Gate state below one workspace runtime
    root. Operator control-plane state is intentionally a separate owner. *)

val dir : base_path:string -> string
val mode : base_path:string -> string
val pending : base_path:string -> string
val replay_results : base_path:string -> string
(** Durable host-replay outcomes live beside, rather than inside,
    [pending.json]. A rollback binary can therefore keep decoding the v8
    pending snapshot while safely ignoring this additive sidecar. *)

val replay_repair_settlements : base_path:string -> string
(** Append-only durable audit of explicit operator settlements for
    process-local replay repair payloads. *)

val always_allowed : base_path:string -> string
