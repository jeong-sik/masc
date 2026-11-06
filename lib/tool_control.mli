(** Tool_control — Flow control operations (pause_status).

    Dispatches [masc_pause_status]. *)

type context = {
  config : Workspace.config;
  agent_name : string;
}

(** {1 Dispatch} *)

(** [dispatch ctx ~name ~args] returns [Some result] for
    [masc_pause_status], else [None]. *)
val dispatch :
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.result option
