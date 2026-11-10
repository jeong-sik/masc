(** After-attempt metadata for the authoritative goal-event JSONL ledger. *)
val subscribe : (base_path:string -> unit) -> (unit -> unit)
(** Non-yielding callback; remove is idempotent. The raw workspace owner is
    preserved and must be resolved by the server worker before publication. *)
val attempted : base_path:string -> unit
(** Include uncertain/cancelled writes without inventing a durable receipt.
    No filesystem work; subscriber failures cannot replace the writer result. *)
val failed_notifications : unit -> int
