module Executor = Keeper_tool_plan_executor
module Journal = Keeper_tool_execution_journal

(* A composition failure goes back to the model when every failed node, called
   directly, would have gone back: its handler's boundary
   (Keeper_tool_failure_boundary) with the effect disposition that node
   reported. A node read-only for the input it ran with also goes back whatever
   its handler, as #35703 let a failed read go back: it left nothing a retry
   would repeat.

   This is same-turn continuation, not permission to replay a graph after a
   provider restart. Only acknowledged atomic settlements keep the provider
   loop open, so every settled node needs a committed receipt, and a graph
   holding a terminal, nested or async node keeps its terminal fence. The
   failed result and its aggregate effect evidence stay intact.

   What a returning failure does not give back is the retry granularity of a
   direct call. A model that made the calls itself retries the one that failed;
   a model that called this macro can only call the macro again, and a node
   that already completed with an effect runs a second time. #35703 accepted
   that for a completed navigation before a failed read, and this rule keeps
   it. The result carries [settled] with each node's effect disposition, so the
   model can see what already ran and call the failed tool directly instead.
   Narrowing this to graphs with no completed effect would fence exactly the
   browser case #35703 opened. *)
let failure_returns_to_model ~plan ~committed (failure : Executor.failure) =
  let ordinary_atomic descriptor =
    match descriptor.Keeper_tool_descriptor.execution, descriptor.tool_kind with
    | Ordinary _, Atomic_tool -> true
    | Terminal, _
    | Ordinary _, (Composition_tool | Async_composition_tool) -> false
  in
  let descriptor node_id = Keeper_tool_plan.descriptor plan node_id in
  let failed_node_returns (node : Executor.node_result) =
    match descriptor node.node_id with
    | None -> false
    | Some d ->
      let disposition =
        match node.failure_effect_disposition with
        | Some disposition -> disposition
        | None -> Tool_result.Effect_outcome_unknown
      in
      ordinary_atomic d
      && (Keeper_tool_descriptor.readonly_for_input d ~input:node.input = Some true
          || not (Keeper_tool_failure_boundary.ends_turn d.Keeper_tool_descriptor.runtime_handler disposition))
  in
  let eligible (node : Executor.node_result) =
    List.exists (fun id -> id = node.execution_id) committed
    && node.output_validation_error = None
    && match node.result with
       | Tool_result.Completed _ -> true
       | Tool_result.Failed _ -> failed_node_returns node
       | Tool_result.Deferred _ -> false
  in
  List.for_all (fun (node : Keeper_tool_plan.node) ->
    match descriptor node.id with Some d -> ordinary_atomic d | None -> false)
    (Keeper_tool_plan.nodes plan)
  && match failure.cause with
     | Executor.Tool_did_not_complete node ->
       (match node.result with
        | Tool_result.Failed _ -> eligible node
          && List.exists (fun (settled : Executor.node_result) -> settled.execution_id = node.execution_id) failure.settled
          && List.for_all eligible failure.settled
        | Tool_result.Completed _ | Tool_result.Deferred _ -> false)
     | Executor.Plan_execution_failed _ | Executor.Node_observation_failed _
     | Executor.Run_journal_rejected _
     | Executor.Outer_completion_mismatch _ -> false
;;

let bind_prepared_result ~composition_run_id ~run_reference ~draft_reference result =
  let binding =
    ["composition_run_id", `String (Keeper_tool_plan.Composition_run_id.to_string composition_run_id);
     "run_artifact", Tool_output.normalized_artifact_ref_to_json run_reference;
     "draft", Tool_output.normalized_artifact_ref_to_json draft_reference] in
  let data = match Tool_result.data result with
    | `Assoc fields -> `Assoc (binding @ List.remove_assoc "composition_run_id" fields)
    | data -> `Assoc (binding @ ["result",data]) in
  let result = match result with
    | Tool_result.Completed payload -> Tool_result.Completed {payload with data}
    | Tool_result.Deferred payload -> Tool_result.Deferred {payload with data}
    | Tool_result.Failed payload -> Tool_result.Failed
      {payload with data_source=Tool_result.Explicit_data data;message=Yojson.Safe.to_string data} in
  Tool_result.with_retained_artifacts
    (run_reference :: draft_reference :: Tool_result.retained_artifacts result) result
;;

type named_admission =
  | Fresh_named of Keeper_skill_activation_recorder.t option
  | Original_child of
      { attempt : Journal.attempt
      ; parent_plan : Keeper_tool_plan.t
      ; origin : Journal.named_origin
      ; context : Keeper_skill_activation_recorder.bound_context
      }

type continuation_recovery =
  | Complete_original_result
  | Hold_original_authority of string

let continuation_recovery_of_result ~effect_disposition result =
  let hold () = Hold_original_authority (Tool_result.message result) in
  match result with
  | Tool_result.Completed _ -> Complete_original_result
  | Tool_result.Deferred _ -> hold ()
  | Tool_result.Failed failure ->
    match failure.class_ with
    | Tool_result.Policy_rejection | Tool_result.Workflow_rejection ->
      (match effect_disposition with
       | Some Tool_result.Proven_pre_effect -> Complete_original_result
       | Some (Tool_result.Proven_post_effect | Tool_result.Effect_outcome_unknown)
       | None -> hold ())
    | Tool_result.Dependency_unavailable | Tool_result.Runtime_failure
    | Tool_result.Operator_cancelled -> hold ()
;;

let node_continuation_recovery (node : Executor.node_result) =
  continuation_recovery_of_result ~effect_disposition:node.failure_effect_disposition node.result

let combine_recovery left right = match left,right with
  | Hold_original_authority _,(Complete_original_result | Hold_original_authority _) -> left
  | Complete_original_result,(Complete_original_result | Hold_original_authority _) -> right
