(** Core entry/provenance helpers for {!Env_config_snapshot}. *)

type entry

type effective_source =
  | Default
  | Environment

val entry :
  ?sensitive:bool -> default:string -> string -> string -> entry

val effective_entry :
  ?sensitive:bool ->
  default:string ->
  read:(unit -> string * effective_source) ->
  string ->
  string ->
  entry

val category : string -> entry list -> string * Yojson.Safe.t
