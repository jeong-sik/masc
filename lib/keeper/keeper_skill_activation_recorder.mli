(** Turn-frozen authority for durable Skill activation recording. *)

type t

type instruction_content =
  | Body of string
  | Resource of
      { relative_path : Skill_resource_path.t
      ; contents : string
      }

type error =
  | Turn_scope_mismatch
  | Runtime_attempt_missing
  | Invalid_task_id of string
  | Composition_reference_missing of { tool_name : string }
  | Activation_rejected of Keeper_skill_activation_ledger.decode_error
  | Store_failed of Keeper_skill_activation_ledger.store_error

val make :
  trace_id:Keeper_id.Trace_id.t ->
  turn_ref:Ids.Turn_ref.t ->
  runtime_id:(unit -> string option) ->
  snapshot_revision:Skill_catalog_snapshot.snapshot_revision ->
  task_scope:Keeper_task_skill_turn.task_scope ->
  (t, error) result
(** Capture the immutable facts used by every Skill call in one turn. The
    runtime provider resolves the concrete candidate selected for the active
    attempt; recording fails before that selection exists. *)

val record_instruction :
  config:Workspace.config ->
  t ->
  invocation:Agent_core.Tool_contract.Invocation.t ->
  content:instruction_content ->
  Skill_reference.t ->
  (Keeper_skill_activation_ledger.record_outcome, error) result

val record_composition :
  config:Workspace.config ->
  t ->
  invocation:Agent_core.Tool_contract.Invocation.t ->
  tool_name:string ->
  Skill_reference.t ->
  (Keeper_skill_activation_ledger.record_outcome, error) result

val observe_delivery :
  config:Workspace.config ->
  t ->
  tool_result_ids:string list ->
  agent_core_turn:int ->
  (string list, error) result

val observe_action :
  config:Workspace.config ->
  t ->
  active_skill_tool_use_ids:string list ->
  invocation:Agent_core.Tool_contract.Invocation.t ->
  tool_name:string ->
  (int, error) result

val error_code : error -> string
val error_to_string : error -> string
val error_to_yojson : error -> Yojson.Safe.t
