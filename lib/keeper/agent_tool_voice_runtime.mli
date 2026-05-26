(** Runtime adapter for client-intercepted voice agent tools. *)

val handle_voice_tool :
  meta:Keeper_types.keeper_meta ->
  name:string ->
  args:Yojson.Safe.t ->
  string
