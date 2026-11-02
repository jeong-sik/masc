(** Exact, read-only terminal observations owned by the reaction ledger.
    The private canonical row decoder stays inside the core library. *)

type selection
(** A validated stimulus id, canonical source snapshot SHA and admitted revision.
    It is an observation target, not authority to acknowledge or replay work. *)

val schema : string

val selections_of_yojson : Yojson.Safe.t -> selection list option
(** Decode a manifest's ordered [intake_sources]. [None] means malformed or
    duplicate exact identities; [Some []] is an observed empty intake. *)

val observe :
  base_path:string -> keeper_name:string -> selection list -> Yojson.Safe.t
(** Stream the owner's current-generation retained ledger. Canonically decoded
    receipts must match all three selection fields. Duplicate projections of
    one receipt coalesce; distinct receipts remain unresolved. Source bodies,
    cancellation reasons and failed-attempt diagnostics are never projected.

    The JSON observation carries its read-end [observed_at], per-source receipt
    references and read coverage. Valid positives survive damaged rows or a
    partial storage read. This is not an atomic queue snapshot: missing receipts
    do not prove current pending status, even when the retained store was read.
    No server module or private decoder type is exposed by this interface. *)
