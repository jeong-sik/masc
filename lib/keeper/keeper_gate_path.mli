(** Single source of truth for Keeper Gate state below one workspace runtime
    root. Operator state is intentionally a separate owner. *)

val dir : base_path:string -> string
val mode : base_path:string -> string
val pending : base_path:string -> string
val replay_results : base_path:string -> string
(** Derived host-replay result references live beside [pending.json].
    Source: one consumed approval plus its exact effect result. Purpose: recover
    that result after restart without executing the effect again. Blast radius:
    one approval's replay delivery; this projection is not authorization state
    and its write failure does not make the pending Gate store unavailable. *)

val always_allowed : base_path:string -> string
