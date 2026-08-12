(** Current-only typed admission for MCP [tools/call] parameters.

    A request has exactly one canonical non-empty string [name]. [arguments]
    is either absent (the MCP-defined empty object) or exactly one JSON object.
    Invalid and duplicate fields are rejected before dispatch. *)

type t
type error

val decode : Yojson.Safe.t option -> (t, error) result
val requested_name : t -> string
val arguments : t -> Yojson.Safe.t
val error_message : error -> string
val error_requested_name : error -> string option
