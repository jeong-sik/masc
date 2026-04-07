(** Keeper voice tool handler — TTS synthesis dispatch. *)

val handle_keeper_voice_tool :
  meta:Keeper_types.keeper_meta ->
  name:string ->
  args:Yojson.Safe.t ->
  string
