(** Tool_control — Flow control operations (pause / pause_status /
    resume).

    Dispatches [masc_pause], [masc_resume], [masc_pause_status]. *)

type tool_result = bool * string

type context = {
  config : Coord.config;
  agent_name : string;
}

(** {1 Handlers} *)

val handle_pause : context -> Yojson.Safe.t -> tool_result

val handle_resume : context -> Yojson.Safe.t -> tool_result

val handle_pause_status : context -> Yojson.Safe.t -> tool_result

(** {1 Dispatch} *)

(** [dispatch ctx ~name ~args] returns [Some result] for
    [masc_pause] / [masc_resume] / [masc_pause_status], else [None]. *)
val dispatch :
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  tool_result option
