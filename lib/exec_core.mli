val process_status_to_json : Unix.process_status -> Yojson.Safe.t

val process_status_of_json : Yojson.Safe.t -> (Unix.process_status, string) result
(** The inverse of {!process_status_to_json}. An object this module did not
    write -- a missing member, a wrong type, an unknown [kind] -- is an
    [Error] naming what is wrong. *)
