(** Durable identities for unanswered TUI Broadcasts. The path belongs to the
    verified workspace; scope distinguishes the server endpoint. Both operations
    serialize with a cross-process journal lock. Errors refuse a new send. *)
val prepare : path:string -> scope:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

(** Retire only the matching committed receipt. Missing/failed receipts retain
    the original identity. A storage failure must remain visible to the user. *)
val acknowledge : path:string -> scope:string -> request:Yojson.Safe.t ->
  Yojson.Safe.t -> (unit, string) result
