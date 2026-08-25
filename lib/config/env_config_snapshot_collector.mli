(** Effect shell for config-snapshot projection.

    A collector performs one owned read and passes the resulting value to
    {!Env_config_snapshot_core}. *)

type t

val entry :
  ?getenv:(string -> string option) ->
  ?sensitive:bool ->
  default:string ->
  string ->
  string ->
  t

val effective_entry :
  ?sensitive:bool ->
  default:string ->
  read:(unit -> string * Env_config_snapshot_core.effective_source) ->
  string ->
  string ->
  t

val to_json : t -> Yojson.Safe.t
val category : string -> t list -> string * Yojson.Safe.t
