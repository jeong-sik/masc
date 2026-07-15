val current_task_id_opt : Keeper_meta_contract.keeper_meta -> string option

val backend_of_meta : Keeper_meta_contract.keeper_meta -> string

val runtime_contract_json :
  config:Workspace.config -> Keeper_meta_contract.keeper_meta -> Yojson.Safe.t
(** Keeper-visible runtime contract. Backend implementation details such as
    [sandbox_profile], [network_mode], [backend], and [sandbox_target] are
    intentionally omitted; use [runtime_observability_contract_json] for
    operator-facing status, receipts, and debugging. *)

val runtime_observability_contract_json :
  config:Workspace.config -> Keeper_meta_contract.keeper_meta -> Yojson.Safe.t
(** Operator-facing runtime contract with sandbox backend details included. *)

val runtime_contract_json_from_fields :
  keeper_name:string ->
  ?agent_name:string ->
  ?trace_id:string ->
  ?session_id:string ->
  ?generation:int ->
  ?keeper_turn_id:int ->
  ?task_id:string ->
  ?sandbox_profile:string ->
  ?sandbox_root:string ->
  ?allowed_paths:string list ->
  ?network_mode:string ->
  ?runtime_profile:string ->
  unit ->
  Yojson.Safe.t
(** Build the keeper-visible runtime contract projection from turn-context
    fields. Backend implementation details are intentionally omitted. *)

val runtime_observability_contract_json_from_fields :
  keeper_name:string ->
  ?agent_name:string ->
  ?trace_id:string ->
  ?session_id:string ->
  ?generation:int ->
  ?keeper_turn_id:int ->
  ?task_id:string ->
  ?sandbox_profile:string ->
  ?sandbox_root:string ->
  ?allowed_paths:string list ->
  ?network_mode:string ->
  ?runtime_profile:string ->
  unit ->
  Yojson.Safe.t
(** Build an operator-facing runtime contract projection from turn-context
    fields, including sandbox backend details for status, receipts, and
    debugging. *)

val action_radius_json :
  tool_name:string ->
  input:Yojson.Safe.t ->
  success:bool ->
  duration_ms:float ->
  ?error:string ->
  ?sandbox_target:string ->
  unit ->
  Yojson.Safe.t
