module Decode = Masc.Tui_decode

type t = {
  observation : Decode.context_observation option;
  error : string option;
}

val empty : t

val resolve_with :
  project:
    (keeper_name:string ->
    current_trace_id:string ->
    (string * Yojson.Safe.t) list) ->
  Decode.keeper ->
  t

val load : config:Workspace_core.config -> Decode.keeper -> t
val for_selection : load:(Decode.keeper -> t) -> Decode.keeper option -> t
