module Decode = Masc.Tui_decode

type reading = {
  observation : Decode.context_observation option;
  error : string option;
}

type t

val empty : t

val reading_for_keeper : keeper_name:string -> t -> reading option

val resolve_with :
  project:
    (keeper_name:string ->
    current_trace_id:string ->
    (string * Yojson.Safe.t) list) ->
  Decode.keeper ->
  t

val load : config:Workspace_core.config -> Decode.keeper -> t
val for_selection : load:(Decode.keeper -> t) -> Decode.keeper option -> t
