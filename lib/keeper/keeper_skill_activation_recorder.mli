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
  | Activation_rejected of Keeper_skill_activation_ledger.decode_error
  | Store_failed of Keeper_skill_activation_ledger.store_error

val make :
  trace_id:Keeper_id.Trace_id.t ->
  turn_ref:Ids.Turn_ref.t ->
  runtime_id:(unit -> string option) ->
  snapshot_revision:Skill_catalog_snapshot.snapshot_revision ->
  task_selection:Keeper_task_skill_turn.t ->
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
  tool_results:Keeper_skill_activation_ledger.tool_result_receipt list ->
  boundary:Keeper_skill_activation_ledger.delivery_boundary ->
  runtime_id:string ->
  (string list, error) result

val observe_action :
  config:Workspace.config ->
  t ->
  active_skill_tool_use_ids:string list ->
  invocation:Agent_core.Tool_contract.Invocation.t ->
  tool_name:string ->
  (int, error) result

val observe_native_action :
  config:Workspace.config -> t -> active_skill_tool_use_ids:string list ->
  runtime_id:string -> agent_core_turn:int ->
  identity:Runtime_native_tools.action_identity -> tool_name:string ->
  (int, error) result
(** [agent_core_turn] is the MASC agent-core turn of the delivery boundary the
    action attaches to — the same axis the ledger compares against
    [delivery.agent_core_turn]. The official client's own session turn counter
    resets per CLI session and must never reach the ledger: a long-lived Keeper
    at agent-core turn N driving a fresh CLI session at claim turn 1 would have
    every legitimate native action rejected as before-delivery. *)

val error_to_string : error -> string
val error_to_yojson : error -> Yojson.Safe.t
