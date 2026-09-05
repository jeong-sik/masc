(** Single source of truth for Keeper Gate state below one workspace runtime
    root. Operator state is intentionally a separate owner. *)

val dir : base_path:string -> string
val mode : base_path:string -> string

val external_mode : base_path:string -> string
(** Operating mode for calls that leave the workspace for an attached outside
    service (Jira, Slack, GitHub). A separate file from {!mode} on purpose:
    the workspace lane gets opened for internal velocity, and that gesture
    must not silently open writes to somebody else's service. *)
val pending : base_path:string -> string
val pending_log : base_path:string -> string
(** Rows appended after the last write of {!pending}: one row per pending
    entry or delivery that changed. The snapshot is rewritten, and this log
    emptied, only when the rows outnumber the entries they describe (see
    [Keeper_approval_queue]). *)
val replay_results : base_path:string -> string
(** Derived host-replay result references live beside [pending.json].
    Source: one consumed approval plus its exact effect result. Purpose: recover
    that result after restart without executing the effect again. Blast radius:
    one approval's replay delivery; this projection is not authorization state
    and its write failure does not make the pending Gate store unavailable. *)

val always_allowed : base_path:string -> string

val keeper_modes : base_path:string -> string
(** Per-Keeper mode overrides, beside the workspace mode rather than inside
    it: one keeper's stance changing must not rewrite the file every other
    keeper's decision is read from. Holds only keepers an operator has
    actually moved, so the file is also the list of them. *)
