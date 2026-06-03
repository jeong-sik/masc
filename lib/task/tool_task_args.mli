(** Task-tool argument parsing helpers. *)

val parse_task_contract :
  Yojson.Safe.t -> (Masc_domain.task_contract option, string) result

val is_internal_marker : string -> bool

val unknown_args : valid_keys:string list -> Yojson.Safe.t -> string list

val synthesize_summary_from_siblings : Yojson.Safe.t -> string option

val transition_action_requires_summary : Masc_domain.task_action -> bool

val parse_handoff_context :
  agent_name:string ->
  action:Masc_domain.task_action ->
  Yojson.Safe.t ->
  (Masc_domain.task_handoff_context option, string) result

val transition_known_args : string list
