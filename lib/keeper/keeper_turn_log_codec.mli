(** The wire shape of a turn log line: one JSON object per line
    (RFC librarian-call-only-proposes §5.1).

    The codec depends on the line types and on ids. It does not depend on the
    Goal or Task stores: a line carries their values as text and ids.

    A refusal is said in {!Keeper_memory_os_types.wire_error}, the words every
    codec here uses for "this node did not decode". That is a dependency of
    the error, not of a line: no value of that module is written into one. *)

val to_json : Keeper_turn_log.line -> Yojson.Safe.t

(** Every object has exactly its fields. Counts and offsets are not negative,
    and a slice takes at least one message. *)
val of_json
  :  Yojson.Safe.t
  -> (Keeper_turn_log.line, Keeper_memory_os_types.wire_error) result
