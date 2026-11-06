(** The ledger value, what can be read from it, and how an activation and an
    empty ledger are made.

    [t] holds one session's activations, transition rejections, async result
    deliveries and async actions, with a memo of its revision. [make] builds a
    [t] from those parts, and [empty] builds the [t] of a workspace root and a
    trace id with nothing recorded. [activations], [transition_rejections],
    [async_result_deliveries], [async_actions], [workspace_key] and
    [session_id] read its fields, and [ledger_revision_to_string] returns a
    revision as a string. [summarize] and [summarize_by_scope] count what [t]
    holds, [usage_for_reference] counts the activations of one skill
    reference, and [summary_to_yojson] and [scoped_summary_to_yojson] render
    the counts. [task_id_set_of_list] and [task_id_set_to_list] convert
    between a list of task ids and the non-empty set an instruction origin
    carries. [validate_served_content] checks a served content and
    [nested_composition_scope] builds a nested composition scope.
    [make_activation_evidence] checks every part of an invocation and builds
    the activation, and [make_activation] calls it with the same arguments.
    [Keeper_skill_activation_ledger] includes this module. *)

open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_errors

type ledger_revision = string

type workspace_key = string

type async_evidence =
  { result_deliveries : Keeper_skill_async_delivery.t list
  ; action_observations : Keeper_skill_async_action.t list
  }

module Delivery_identity_set : Set.S with type elt = string

(* The revision is the SHA-256 of the whole canonical ledger, so computing it
   costs a serialisation of every activation. A mutation does not need it --
   only a reader that projects or verifies the ledger does -- so it is computed
   on the first read and kept with the value. The fields it covers are
   immutable, so two readers that race to fill it write the same string. *)
type t =
  { workspace_key : workspace_key
  ; session_id : Keeper_id.Trace_id.t
  ; activations : activation list
  ; transition_rejections : transition_rejection list
  ; async_result_deliveries : Keeper_skill_async_delivery.t list
  ; async_actions : Keeper_skill_async_action.t list
  ; mutable revision_memo : ledger_revision option
  }

type record_outcome =
  | Recorded of activation
  | Already_recorded of activation

val activations : t -> activation list

val transition_rejections :
  t -> transition_rejection list

val async_result_deliveries : t -> Keeper_skill_async_delivery.t list

val async_actions : t -> Keeper_skill_async_action.t list

val ledger_revision_to_string : ledger_revision -> string

val workspace_key : t -> string

val session_id : t -> Keeper_id.Trace_id.t

val task_id_set_to_list :
  task_id_set -> Keeper_id.Task_id.t list

val task_id_set_of_list :
  Keeper_id.Task_id.t list ->
  (task_id_set,
   decode_error)
  result

val summarize : t -> summary

type catalog_usage =
  { invocations : int
  ; received_invocations : int
  ; observed_actions : int
  ; last_activated_at : string
  }

val usage_for_reference : t -> Skill_reference.t -> catalog_usage option

val summarize_by_scope :
  t -> scoped_summary list

val summary_to_yojson :
  summary -> Yojson.Safe.t

val scoped_summary_to_yojson :
  scoped_summary -> Yojson.Safe.t

val rejection_activation_turn_ref :
  transition_rejection -> Ids.Turn_ref.t

val validate_served_content :
  served_content ->
  (unit, decode_error) result

val nested_composition_scope :
  parent_tool_use_id:string ->
  composition_run_id:string ->
  alias:string ->
  (nested_composition_scope,
   decode_error)
  result

val make_activation_evidence :
  identity:Skill_reference.identity ->
  content_revision:Skill_reference.content_revision ->
  snapshot_revision:Skill_catalog_snapshot.snapshot_revision ->
  turn_ref:Ids.Turn_ref.t ->
  runtime_id:string ->
  skill_tool_use_id:string ->
  agent_core_turn:int ->
  invocation:invocation ->
  activated_at:string ->
  (activation,
   decode_error)
  result

val make_activation :
  identity:Skill_reference.identity ->
  content_revision:Skill_reference.content_revision ->
  snapshot_revision:Skill_catalog_snapshot.snapshot_revision ->
  turn_ref:Ids.Turn_ref.t ->
  runtime_id:string ->
  skill_tool_use_id:string ->
  agent_core_turn:int ->
  invocation:invocation ->
  activated_at:string ->
  (activation,
   decode_error)
  result

val make :
  workspace_key:string ->
  session_id:Keeper_id.Trace_id.t ->
  activations:activation list ->
  transition_rejections:transition_rejection
                        list ->
  async_result_deliveries:Keeper_skill_async_delivery.t list ->
  async_actions:Keeper_skill_async_action.t list -> t

val empty :
  workspace_root:string -> trace_id:Keeper_id.Trace_id.t -> t
