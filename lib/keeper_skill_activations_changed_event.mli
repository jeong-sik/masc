(** A Keeper's skill activation ledger took a record: an activation, a
    delivery, an action, an async fact or a rejected transition. It names the
    Keeper and its trace and carries nothing else; a reader that shows that
    Keeper's activations or usage reads them again (RFC-0483). *)

val event_type : string

val json : name:string -> trace_id:string -> ts_unix:float -> Yojson.Safe.t
