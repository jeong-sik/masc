(** Producer-supplied invocation identity shared by durable queues and
    repetition evidence. Identity is never inferred from prompt text or time. *)
type t
val direct_operation : Keeper_chat_operation.Operation_id.t -> t
val autonomous_admission : Uuidm.t -> t
val compare : t -> t -> int
val equal : t -> t -> bool
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
