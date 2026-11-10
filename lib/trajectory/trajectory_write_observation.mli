(** Metadata from actual trajectory file write attempts, including uncertain
    and cancelled attempts. This grants no durable receipt or retry authority. *)
type owner = { masc_root : string; keeper_name : string }
(** Original owner spelling, retained by the writer across global re-init.
    A server subscriber resolves this root before matching its workspace;
    it must never infer an unknown owner from the current workspace. *)
val subscribe : (owner -> unit) -> (unit -> unit)
(** Synchronous non-yielding metadata callbacks; removal is idempotent. The
    server records read debt and does not read/fan out inline. *)
val attempted : owner -> unit
(** No filesystem work. Callback exceptions, including cancellation, cannot
    replace the original writer result or cancel its cleanup. *)
val failed_notifications : unit -> int
