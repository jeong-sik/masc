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

val targets_of_strings :
  target_type:string option ->
  target_ids:string option ->
  (target list, error) result
(** Parse one comma-separated [target_ids] into targets of one type. A board
    page asks about its rows together rather than once each. *)

val toggle_request_of_json : Yojson.Safe.t -> (toggle_request, error) result

val malformed_json : string -> error

val catalog_json : unit -> Yojson.Safe.t

val list_json :
  actor:string -> target -> (Yojson.Safe.t, error) result

val list_batch_json : actor:string -> target list -> Yojson.Safe.t
(** Reaction state for every target asked about, keyed by [target_id]. A target
    the store has nothing for answers with an empty list rather than being
    left out. *)

val toggle_json :
  actor:string -> toggle_request -> (Yojson.Safe.t, error) result

val error_status : error -> http_status
val error_json : error -> Yojson.Safe.t
