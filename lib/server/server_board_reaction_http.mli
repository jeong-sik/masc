(** Typed HTTP projection for Board reactions.

    The Board domain owns reaction validation, persistence, and the supported
    emoji catalog.  HTTP/1.1 and HTTP/2 adapters only authenticate the actor,
    parse their transport payload, and render this shared result. *)

type target
type toggle_request
type error

type http_status =
  [ `Bad_request
  | `Conflict
  | `Forbidden
  | `Internal_server_error
  | `Not_found
  | `Too_many_requests
  ]

val target_of_strings :
  target_type:string option ->
  target_id:string option ->
  (target, error) result

val toggle_request_of_json : Yojson.Safe.t -> (toggle_request, error) result

val malformed_json : string -> error

val catalog_json : unit -> Yojson.Safe.t

val list_json :
  actor:string -> target -> (Yojson.Safe.t, error) result

val toggle_json :
  actor:string -> toggle_request -> (Yojson.Safe.t, error) result

val error_status : error -> http_status
val error_json : error -> Yojson.Safe.t
