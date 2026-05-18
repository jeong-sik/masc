(** Core entry/provenance helpers for {!Env_config_snapshot}. *)

type entry

val entry :
  ?sensitive:bool -> default:string -> string -> string -> entry

val category : string -> entry list -> string * Yojson.Safe.t
