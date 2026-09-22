(** A value the code that publishes onto an {!Event_bus} hands the bus, which
    the bus stamps on every event it publishes and Agent Core never reads.

    The caller decides what a scope means and is the only party that can turn
    one back into meaning. Agent Core carries it verbatim from the bus handle
    to {!Event_envelope.t}, so a subscriber can say which piece of the caller's
    work an event belongs to without guessing from event order or time.

    The type is abstract so that nothing inside Agent Core can branch on a
    scope's contents. A scope is never blank: a caller with nothing to say
    publishes on a bus without one. *)

type t

(** [of_string value] is the scope spelled [value]. A blank [value] is not a
    scope and is refused. *)
val of_string : string -> (t, string) result

val to_string : t -> string
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
