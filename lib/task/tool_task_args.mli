(** Task-tool argument parsing helpers. *)

val parse_task_contract :
  Yojson.Safe.t -> (Masc_domain.task_contract option, string) result

(** Decode a present public tool [contract] value. Unlike the permissive
    persisted-data decoder, this boundary rejects unknown and duplicate fields. *)
val parse_task_contract_object :
  Yojson.Safe.t -> (Masc_domain.task_contract, string) result

val is_internal_marker : string -> bool

val unknown_args : valid_keys:string list -> Yojson.Safe.t -> string list

val parse_handoff_context :
  agent_name:string ->
  action:Masc_domain.task_action ->
  Yojson.Safe.t ->
  (Masc_domain.task_handoff_context option, string) result

val transition_known_args : string list
