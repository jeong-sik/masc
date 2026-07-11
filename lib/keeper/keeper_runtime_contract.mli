val current_task_id_opt : Keeper_meta_contract.keeper_meta -> string option
val primary_goal_id_opt : Keeper_meta_contract.keeper_meta -> string option

val validate_active_goal_ids :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  string list
(** Cross-check [meta.active_goal_ids] against the live MASC goal store.
    Returns only goal IDs that actually exist. Logs pruned IDs at warn level. *)

val backend_of_meta : Keeper_meta_contract.keeper_meta -> string
val task_is_linked_to_keeper_goals :
  ?task_goal_index:(string, string list) Hashtbl.t -> string list -> Masc_domain.task -> bool

type claim_scope_mode =
  | All_tasks
  | Active_goal_ids
  | Empty_goal_scope_fallback_all_tasks

val claim_scope_mode_to_string : claim_scope_mode -> string
(** Wire label for a claim-scope mode (e.g. observation JSON). Closed variant
    (#20674) so producers/consumers stay exhaustive instead of drifting on a
    bare [string]. *)

type claim_goal_scope = {
  task_filter : Masc_domain.task -> bool;
  mode : claim_scope_mode;
  effective_goal_ids : string list;
  fallback_reason : string option;
}

val resolve_claim_goal_scope :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  claim_goal_scope

val resolve_claim_goal_scope_for_tasks :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  tasks:Masc_domain.task list ->
  unit ->
  claim_goal_scope
(** Backlog-aware claim scope for callers that already loaded tasks. This
    avoids re-reading the backlog while preserving the empty-scope fallback. *)

val resolve_observation_claim_goal_scope :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  claim_goal_scope
(** Signal-only claim scope for world observations. *)

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
  ?goal_ids:string list ->
  ?sandbox_profile:string ->
  ?sandbox_root:string ->
  ?allowed_paths:string list ->
  ?network_mode:string ->
  ?approval_mode:string ->
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
  ?goal_ids:string list ->
  ?sandbox_profile:string ->
  ?sandbox_root:string ->
  ?allowed_paths:string list ->
  ?network_mode:string ->
  ?approval_mode:string ->
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
