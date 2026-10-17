(** Turn-frozen authority for durable Skill activation recording. *)

type t
type bound_context
val physical_turn_ref : t -> Ids.Turn_ref.t
val current_runtime_id : t -> string option
val task_references : task_id:Keeper_id.Task_id.t -> t -> Skill_reference.t list
(** Exact references selected by this Task in the immutable turn frame. This
    reads no source, resolves no runtime and records no activation. Held Tasks
    without this exact Task identity and unavailable references are excluded. *)
type result_child =
  { alias : string
  ; skill_reference : Skill_reference.t
  ; skill_tool_use_id : string
  ; activation_frame_sha256 : string
  }
val bound_trace_id : bound_context -> Keeper_id.Trace_id.t
val bound_turn_ref : bound_context -> Ids.Turn_ref.t

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
  | Invalid_bound_context of string

val find_bound_result_children : config:Workspace.config -> bound_context ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  logical_parent_tool_use_id:string -> source_turn:int -> tool_name:string ->
  result_child list -> (Keeper_skill_activation_ledger.activation list, error) result
(** One strict ledger read for all admitted original children. Compare every
    original Task/reference/runtime/snapshot/turn against the sealed recorder;
    missing or changed admitted children do not create replacement activations.
    Each result's retained immutable activation frame must match the original
    ledger, including its first activation clock. *)

val bind_async : t -> (bound_context, error) result
(** Resolve the selected runtime once, keeping the original trace, turn,
    snapshot and exact Task provenance. This records no activation. *)
val bound_context_to_yojson : bound_context -> Yojson.Safe.t
val bound_context_of_yojson : Yojson.Safe.t -> (bound_context, error) result
(** Strict immutable run-evidence codec. Only a sealed owned run supplies this
    authority; a model's recipe cannot supply or replace it. *)
val bound_task_references : bound_context -> Skill_reference.t list
val find_bound_nested : config:Workspace.config -> bound_context ->
  invocation:Agent_core.Tool_contract.Invocation.t -> tool_name:string ->
  scope:Keeper_skill_activation_ledger.nested_composition_scope ->
  reference:Skill_reference.t ->
  (Keeper_skill_activation_ledger.activation option, error) result
val record_bound_nested : config:Workspace.config -> bound_context ->
  invocation:Agent_core.Tool_contract.Invocation.t -> tool_name:string ->
  scope:Keeper_skill_activation_ledger.nested_composition_scope ->
  reference:Skill_reference.t ->
  (Keeper_skill_activation_ledger.record_outcome, error) result
(** Reuse an existing exact activation and its original activation clock under
    the canonical ledger transaction. New children activate only at admission. *)

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

val find_bound_composition : config:Workspace.config -> bound_context ->
  tool_use_id:string -> source_turn:int -> tool_name:string -> Skill_reference.t ->
  (Keeper_skill_activation_ledger.activation option, error) result
(** Strict original standalone composition lookup; never records a replacement.
    Preserve the original activation clock and compare the complete bound frame. *)

val record_bound_composition :
  config:Workspace.config -> bound_context ->
  invocation:Agent_core.Tool_contract.Invocation.t -> tool_name:string ->
  Skill_reference.t ->
  (Keeper_skill_activation_ledger.record_outcome, error) result
(** Record with the exact already-sealed runtime, Task and turn facts. The
    runtime provider is not evaluated again during named source preparation. *)

val record_nested_composition :
  config:Workspace.config -> t ->
  invocation:Agent_core.Tool_contract.Invocation.t ->
  tool_name:string -> scope:Keeper_skill_activation_ledger.nested_composition_scope ->
  Skill_reference.t ->
  (Keeper_skill_activation_ledger.record_outcome, error) result
(** Record one attempted child invocation at dispatch admission, with a unique
    child invocation ID. The enclosing Tool result carries its delivery. Never
    call this merely because a draft was prepared or a child was selected. *)

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
