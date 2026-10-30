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
  ?delivery_parent_tool_use_id:string ->
  calls:Keeper_composition_nested.call list ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  parent_invocation:Agent_core.Tool_contract.Invocation.t ->
  tool_name:string ->
  record_activation:record_activation option -> unit -> t

val async_result_parent : Keeper_tool_plan.Composition_run_id.t -> string
(** Stable final-result receipt identity across original request successors.
    The initial async submission receipt cannot deliver child results. *)

val admit_node : t -> node:Keeper_tool_plan.node ->
  (unit, Keeper_tool_plan_executor.admission_rejection) result
(** Persist a child activation before its first ordinary leaf handler. Cache
    that result under a per-run Eio mutex, so concurrently ready sibling leaves
    share one admission. A rejection is proven before any leaf effect. *)

val admitted_activation : t -> alias:Keeper_tool_plan.Node_id.t ->
  (Keeper_skill_activation_ledger.activation,
   Keeper_tool_plan_executor.admission_rejection) result
(** Read the exact receipt retained by successful admission or original-ledger
    restoration. Unknown, unstarted and rejected children remain errors. This
    lookup records nothing, reconstructs no activation and grants no broker or
    current-ledger authority; a producer must still check its owned source. *)

val restore_admissions : t ->
  find_activation:(invocation:Agent_core.Tool_contract.Invocation.t -> tool_name:string ->
    scope:Keeper_skill_activation_ledger.nested_composition_scope -> reference:Skill_reference.t ->
    (Keeper_skill_activation_ledger.activation option, Keeper_skill_activation_recorder.error) result) -> unit
(** Before dispatch, restore only exact already-recorded child admissions from
    the original ledger. Absent children remain unstarted; lookup failures
    refuse admission without creating an activation. *)

type original_admission =
  | Original_admitted
  | Original_authority_held of Keeper_tool_plan_executor.admission_rejection

val check_original_admissions : t ->
  child_history:(node_ids:Keeper_tool_plan.Node_id.t list ->
    (Keeper_tool_execution_journal.child_admission_history,
     Keeper_tool_execution_journal.error) result) ->
  original_admission
(** Require exact original activation for a child whose journal nodes prove
    prior admission or an unfinished attempt. Run this before acceptance and
    again before result reuse. Missing authority does not become fresh work.
    This boundary reads original evidence; a held result is recoverable and
    never proves a permanent current-policy rejection. *)

val evidence_to_json : t -> plan:Keeper_tool_plan.t ->
  execution:(Keeper_tool_plan_executor.node_result list,
             Keeper_tool_plan_executor.failure) result -> Yojson.Safe.t
(** Exact child scope, admission, own leaf settlements, aggregate disposition
    and individually available exports. Parent failure does not silently turn
    a child into success. Blocked scopes remain explicitly not started. *)
