(** Run-owned child admission and settlement evidence. Preparing a recipe
    never records activation; only a validated ready leaf may enter a scope. *)

type record_activation =
  invocation:Agent_core.Tool_contract.Invocation.t ->
  tool_name:string ->
  scope:Keeper_skill_activation_ledger.nested_composition_scope ->
  reference:Skill_reference.t ->
  (Keeper_skill_activation_ledger.record_outcome,
   Keeper_skill_activation_recorder.error) result

type t

val create :
  calls:Keeper_composition_nested.call list ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  parent_invocation:Agent_core.Tool_contract.Invocation.t ->
  tool_name:string ->
  record_activation:record_activation option -> t

val admit_node : t -> node:Keeper_tool_plan.node ->
  (unit, Keeper_tool_plan_executor.admission_rejection) result
(** Persist a child activation before its first ordinary leaf handler. Cache
    that result under a per-run Eio mutex, so concurrently ready sibling leaves
    share one admission. A rejection is proven before any leaf effect. *)

val evidence_to_json : t -> plan:Keeper_tool_plan.t ->
  execution:(Keeper_tool_plan_executor.node_result list,
             Keeper_tool_plan_executor.failure) result -> Yojson.Safe.t
(** Exact child scope, admission, own leaf settlements, aggregate disposition
    and individually available exports. Parent failure does not silently turn
    a child into success. Blocked scopes remain explicitly not started. *)
