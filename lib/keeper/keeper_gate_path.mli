(** Single source of truth for Keeper Gate state below one workspace runtime
    root. Operator control-plane state is intentionally a separate owner. *)

val dir : base_path:string -> string
val mode : base_path:string -> string
val pending : base_path:string -> string
val replay_results : base_path:string -> string
(** Durable host-replay outcomes live beside [pending.json]. Keeping them in
    an additive sidecar preserves the pending snapshot wire contract while
    allowing blob-backed evidence to survive process restart. *)

val always_allowed : base_path:string -> string
