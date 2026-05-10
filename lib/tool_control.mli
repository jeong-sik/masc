
(** Tool_control — Flow control operations (pause / pause_status /
    resume).

    Dispatches [masc_pause], [masc_resume], [masc_pause_status]. *)

type context = {
  config : Coord.config;
  agent_name : string;
}

(** {1 Handlers} *)

val handle_pause :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t

val handle_resume :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t

val handle_pause_status :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.t

(** {1 Dispatch} *)

(** [dispatch ctx ~name ~args] returns [Some result] for
    [masc_pause] / [masc_resume] / [masc_pause_status], else [None]. *)
val dispatch :
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.t option
