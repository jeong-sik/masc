(** Durable identities for unanswered TUI Broadcasts. The path belongs to the
    verified workspace; scope distinguishes the server endpoint. A nonsecret credential fingerprint
    binds an unanswered operation to the credential used before sending; changed
    or legacy-unbound credentials refuse replay without replacing its ID. Both operations
    serialize with a cross-process journal lock. Errors refuse a new send. *)
val prepare : path:string -> scope:string -> credential:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

(** Retire only a matching committed receipt whose immediate fanout handler has
    finished, or whose durable recipient ledger has accepted recovery ownership.
    Unfinished immediate fanout keeps the identity for cancellation recovery.
    Missing/failed receipts retain the identity; malformed committed receipts
    and storage failures remain visible to the user. *)
val acknowledge : path:string -> scope:string -> credential:string -> request:Yojson.Safe.t ->
  Yojson.Safe.t -> (unit, string) result
