type scheduled_node =
  { node : Keeper_tool_plan.node
  ; descriptor : Keeper_tool_descriptor.t
  ; schedule : Agent_core.Tool_contract.schedule
  }

type batch =
  | Serial_batch of scheduled_node
  | Concurrent_batch of scheduled_node list

type unscheduled_batch =
  | Unscheduled_serial of Keeper_tool_plan.node * Keeper_tool_descriptor.t
  | Unscheduled_concurrent of (Keeper_tool_plan.node * Keeper_tool_descriptor.t) list

let execution_mode_of_descriptor descriptor =
  match descriptor.Keeper_tool_descriptor.execution with
  | Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Concurrent ->
    Agent_core.Tool_contract.Concurrent
  | Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Serial
  | Keeper_tool_descriptor.Terminal -> Agent_core.Tool_contract.Serial
;;

let descriptor_exn plan node =
  match Keeper_tool_plan.descriptor plan node.Keeper_tool_plan.id with
  | Some descriptor -> descriptor
  | None ->
    invalid_arg
      (Printf.sprintf
         "validated composition plan lost descriptor for node %s"
         (Keeper_tool_plan.Node_id.to_string node.id))
;;

let unscheduled_layer plan nodes =
  let flush_concurrent batches = function
    | [] -> batches
    | concurrent -> Unscheduled_concurrent (List.rev concurrent) :: batches
  in
  let rec build batches concurrent = function
    | [] -> List.rev (flush_concurrent batches concurrent)
    | node :: rest ->
      let descriptor = descriptor_exn plan node in
      (match descriptor.Keeper_tool_descriptor.execution with
       | Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Concurrent ->
         build batches ((node, descriptor) :: concurrent) rest
       | Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Serial
       | Keeper_tool_descriptor.Terminal ->
         let batches = flush_concurrent batches concurrent in
         build (Unscheduled_serial (node, descriptor) :: batches) [] rest)
  in
  build [] [] nodes
;;

let schedule plan =
  let planned_indexes =
    Keeper_tool_plan.nodes plan
    |> List.mapi (fun index node -> node.Keeper_tool_plan.id, index)
  in
  let planned_index node =
    match
      List.find_opt
        (fun (id, _) -> Keeper_tool_plan.Node_id.equal id node.Keeper_tool_plan.id)
        planned_indexes
    with
    | Some (_, index) -> index
    | None -> invalid_arg "validated composition plan lost a canonical node"
  in
  Keeper_tool_plan.dependency_layers plan
  |> List.concat_map (unscheduled_layer plan)
  |> List.mapi (fun batch_index batch ->
    let scheduled_node ~batch_size (node, descriptor) =
      { node
      ; descriptor
      ; schedule =
          { Agent_core.Tool_contract.planned_index = planned_index node
          ; batch_index
          ; batch_size
          ; execution_mode = execution_mode_of_descriptor descriptor
          }
      }
    in
    match batch with
    | Unscheduled_serial (node, descriptor) ->
      Serial_batch (scheduled_node ~batch_size:1 (node, descriptor))
    | Unscheduled_concurrent nodes ->
      let batch_size = List.length nodes in
      Concurrent_batch (List.map (scheduled_node ~batch_size) nodes))
;;

let outer_completion plan =
  if
    List.exists
      (fun node ->
         match Keeper_tool_plan.descriptor plan node.Keeper_tool_plan.id with
         | Some { Keeper_tool_descriptor.execution = Keeper_tool_descriptor.Terminal; _ } ->
           true
         | Some
             { execution =
                 Keeper_tool_descriptor.Ordinary
                   (Keeper_tool_descriptor.Serial | Keeper_tool_descriptor.Concurrent)
             ; _
             }
         | None -> false)
      (Keeper_tool_plan.nodes plan)
  then
    Agent_core.Tool_contract.Terminal_after_success
      Agent_core.Tool_contract.Effect_outcome_unknown
  else Agent_core.Tool_contract.Continue_after_success
;;

type node_result =
  { node_id : Keeper_tool_plan.Node_id.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; schedule : Agent_core.Tool_contract.schedule
  ; result : Tool_result.result
  ; tool_use_id : string option
  ; failure_effect_disposition : Tool_result.failure_effect_disposition option
  ; deferred_kind : Keeper_tool_execution.deferred_kind option
  }

type dispatch_result =
  { result : Tool_result.result
  ; tool_use_id : string option
  ; failure_effect_disposition : Tool_result.failure_effect_disposition option
  ; deferred_kind : Keeper_tool_execution.deferred_kind option
  }

let dispatch_result ?tool_use_id ?failure_effect_disposition ?deferred_kind result =
  { result; tool_use_id; failure_effect_disposition; deferred_kind }
;;

type cause =
  | Plan_execution_failed of
      { node_id : Keeper_tool_plan.Node_id.t
      ; schedule : Agent_core.Tool_contract.schedule
      ; error : Keeper_tool_plan.execution_error
      }
  | Tool_did_not_complete of node_result
  | Node_observation_failed of
      { node : node_result
      ; detail : string
      }
  | Outer_completion_mismatch of
      { expected : Agent_core.Tool_contract.completion
      ; actual : Agent_core.Tool_contract.completion
      }

type failure =
  { settled : node_result list
  ; cause : cause
  ; effect_disposition : Tool_result.failure_effect_disposition
  }

type dispatch =
  node:Keeper_tool_plan.node
  -> descriptor:Keeper_tool_descriptor.t
  -> schedule:Agent_core.Tool_contract.schedule
  -> input:Yojson.Safe.t
  -> dispatch_result

type node_settlement =
  { result : node_result option
  ; output : Keeper_tool_plan.output option
  ; cause : cause option
  }

let execute_one ~plan ~run_id ~outputs ~dispatch ?observe_node_result scheduled =
  let node = scheduled.node in
  let node_id = node.Keeper_tool_plan.id in
  let plan_failure error =
    { result = None
    ; output = None
    ; cause = Some (Plan_execution_failed { node_id; schedule = scheduled.schedule; error })
    }
  in
  match
    Keeper_tool_plan.resolve_input
      plan
      ~run_id
      ~node_id
      ~lookup:(fun dependency ->
        List.find_map
          (fun (id, output) ->
             if Keeper_tool_plan.Node_id.equal id dependency then Some output else None)
          outputs)
  with
  | Error error -> plan_failure error
  | Ok input ->
    let start_time = Time_compat.now () in
    let result =
      Cancel_safe.protect
        ~on_exn:(fun exn ->
          dispatch_result
            ~failure_effect_disposition:Tool_result.Effect_outcome_unknown
            (Tool_result.make_err_of_exn
               ~class_:Tool_result.Runtime_failure
               ~tool_name:node.tool_name
               ~start_time
               exn))
        (fun () ->
           dispatch
             ~node
             ~descriptor:scheduled.descriptor
             ~schedule:scheduled.schedule
             ~input)
    in
    let node_result =
      { node_id
      ; tool_name = node.tool_name
      ; input
      ; schedule = scheduled.schedule
      ; result = result.result
      ; tool_use_id = result.tool_use_id
      ; failure_effect_disposition = result.failure_effect_disposition
      ; deferred_kind = result.deferred_kind
      }
    in
    let observation_error =
      match observe_node_result with
      | None -> None
      | Some observe ->
        (try
           match observe node_result with
           | Ok () -> None
           | Error detail -> Some detail
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn -> Some (Printexc.to_string exn))
    in
    (match observation_error with
     | Some detail ->
       { result = Some node_result
       ; output = None
       ; cause = Some (Node_observation_failed { node = node_result; detail })
       }
     | None ->
       (match result.result with
     | Tool_result.Deferred _ | Tool_result.Failed _ ->
       { result = Some node_result
       ; output = None
       ; cause = Some (Tool_did_not_complete node_result)
       }
     | Tool_result.Completed _ ->
       (match scheduled.descriptor.Keeper_tool_descriptor.composable_output with
        | Keeper_tool_descriptor.Opaque_output ->
          { result = Some node_result; output = None; cause = None }
        | Keeper_tool_descriptor.Json_output _ ->
          (match
             Keeper_tool_plan.validate_output
               plan
               ~run_id
               ~node_id
               (Tool_result.data result.result)
           with
           | Ok output ->
             { result = Some node_result; output = Some output; cause = None }
           | Error error ->
             { result = Some node_result
             ; output = None
             ; cause =
                 Some
                   (Plan_execution_failed
                      { node_id; schedule = scheduled.schedule; error })
             }))))
;;

let execute ~plan ~run_id ~dispatch ?observe_node_result () =
  let node_effect_disposition (result : node_result) =
    match result.result with
    | Tool_result.Deferred _ -> Tool_result.Proven_pre_effect
    | Tool_result.Failed _ ->
      Option.value
        ~default:Tool_result.Effect_outcome_unknown
        result.failure_effect_disposition
    | Tool_result.Completed _ ->
      (match Keeper_tool_plan.descriptor plan result.node_id with
       | Some descriptor
         when Keeper_tool_descriptor.readonly_for_input descriptor ~input:result.input
              = Some true ->
         Tool_result.Proven_pre_effect
       | Some _ | None -> Tool_result.Proven_post_effect)
  in
  let aggregate_effect_disposition settled =
    List.fold_left
      (fun aggregate result ->
         match aggregate, node_effect_disposition result with
         | Tool_result.Proven_post_effect, _
         | _, Tool_result.Proven_post_effect ->
           Tool_result.Proven_post_effect
         | Tool_result.Effect_outcome_unknown, _
         | _, Tool_result.Effect_outcome_unknown ->
           Tool_result.Effect_outcome_unknown
         | Tool_result.Proven_pre_effect, Tool_result.Proven_pre_effect ->
           Tool_result.Proven_pre_effect)
      Tool_result.Proven_pre_effect
      settled
  in
  let rec run_batches settled outputs = function
    | [] -> Ok settled
    | batch :: rest ->
      let execute scheduled =
        execute_one
          ~plan
          ~run_id
          ~outputs
          ~dispatch
          ?observe_node_result
          scheduled
      in
      let settlements =
        match batch with
        | Serial_batch scheduled -> [ execute scheduled ]
        | Concurrent_batch scheduled -> Eio.Fiber.List.map execute scheduled
      in
      let batch_results = List.filter_map (fun settlement -> settlement.result) settlements in
      let settled = settled @ batch_results in
      (match List.find_map (fun settlement -> settlement.cause) settlements with
       | Some cause ->
         Error
           { settled
           ; cause
           ; effect_disposition = aggregate_effect_disposition settled
           }
       | None ->
         let outputs =
           List.fold_left
             (fun outputs settlement ->
                match settlement.output with
                | None -> outputs
                | Some output ->
                  (Keeper_tool_plan.output_node_id output, output) :: outputs)
             outputs
             settlements
         in
         run_batches settled outputs rest)
  in
  run_batches [] [] (schedule plan)
;;

let nested_tool_use_id ~composition_run_id parent_invocation node_id =
  let parent = Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation in
  let node = Keeper_tool_plan.Node_id.to_string node_id in
  let run = Keeper_tool_plan.Composition_run_id.to_string composition_run_id in
  Printf.sprintf
    "composition:%d:%s:%d:%s:%d:%s"
    (String.length run)
    run
    (String.length parent)
    parent
    (String.length node)
    node
;;

let equal_failure_effect left right =
  match left, right with
  | Agent_core.Tool_contract.Proven_pre_effect, Agent_core.Tool_contract.Proven_pre_effect
  | Agent_core.Tool_contract.Proven_post_effect, Agent_core.Tool_contract.Proven_post_effect
  | Agent_core.Tool_contract.Effect_outcome_unknown, Agent_core.Tool_contract.Effect_outcome_unknown -> true
  | ( Agent_core.Tool_contract.Proven_pre_effect
    | Agent_core.Tool_contract.Proven_post_effect
    | Agent_core.Tool_contract.Effect_outcome_unknown )
  , ( Agent_core.Tool_contract.Proven_pre_effect
    | Agent_core.Tool_contract.Proven_post_effect
    | Agent_core.Tool_contract.Effect_outcome_unknown ) -> false
;;

let equal_completion left right =
  match left, right with
  | Agent_core.Tool_contract.Continue_after_success, Agent_core.Tool_contract.Continue_after_success -> true
  | Agent_core.Tool_contract.Terminal_after_success left,
    Agent_core.Tool_contract.Terminal_after_success right ->
    equal_failure_effect left right
  | Agent_core.Tool_contract.Continue_after_success,
    Agent_core.Tool_contract.Terminal_after_success _
  | Agent_core.Tool_contract.Terminal_after_success _,
    Agent_core.Tool_contract.Continue_after_success -> false
;;

let execute_keeper
      ~plan
      ~run_id
      ?composition_run_id
      ~parent_invocation
      ~config
      ~meta
      ~publication_recovery
      ~ctx_snapshot
      ?turn_sandbox_factory
      ?clock
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ?record_gate_result
      ?on_completed
      ?on_deferred
      ?on_external_effect_deferred
      ?on_failed
      ?observe_node_result
      ()
  =
  let composition_run_id =
    Option.value
      ~default:(Keeper_tool_plan.Composition_run_id.fresh ())
      composition_run_id
  in
  let expected_completion = outer_completion plan in
  let actual_completion =
    Agent_core.Tool_contract.Invocation.completion parent_invocation
  in
  if not (equal_completion expected_completion actual_completion)
  then
    Error
      { settled = []
      ; cause =
          Outer_completion_mismatch
            { expected = expected_completion; actual = actual_completion }
      ; effect_disposition = Tool_result.Proven_pre_effect
      }
  else
  let dispatch ~(node : Keeper_tool_plan.node) ~descriptor ~schedule ~input =
    let terminal_on_completed, terminal_on_failed =
      match descriptor.Keeper_tool_descriptor.execution with
      | Keeper_tool_descriptor.Terminal -> on_completed, on_failed
      | Keeper_tool_descriptor.Ordinary
          (Keeper_tool_descriptor.Serial | Keeper_tool_descriptor.Concurrent) -> None, None
    in
    let execution_evidence = ref None in
    let handler =
      Keeper_tools_agent_core_handler.make_keeper_tool_handler
        ~name:descriptor.internal_name
        ~descriptor
        ~model_name:node.tool_name
        ~input_schema:descriptor.input_schema
        ~config
        ~meta
        ~publication_recovery
        ~ctx_snapshot
        ?turn_sandbox_factory
        ?clock
        ?continuation_channel
        ?gate_context
        ?gate_grant
        ?record_gate_result
        ~observe_execution_evidence:(fun ~failure_effect_disposition ~deferred_kind ->
          execution_evidence := Some (failure_effect_disposition, deferred_kind))
        ?on_completed:terminal_on_completed
        ?on_deferred
        ?on_external_effect_deferred
        ?on_failed:terminal_on_failed
        ()
    in
    let invocation =
      Agent_core.Tool_contract.Invocation.create
        ~tool_use_id:
          (nested_tool_use_id ~composition_run_id parent_invocation node.id)
        ~turn:(Agent_core.Tool_contract.Invocation.turn parent_invocation)
        ~schedule
        ~completion:Agent_core.Tool_contract.Continue_after_success
    in
    let result = handler ~agent_core_invocation:invocation input in
    match !execution_evidence with
    | Some (failure_effect_disposition, deferred_kind) ->
      { result
      ; tool_use_id = Some (Agent_core.Tool_contract.Invocation.tool_use_id invocation)
      ; failure_effect_disposition
      ; deferred_kind
      }
    | None ->
      dispatch_result
        ~tool_use_id:(Agent_core.Tool_contract.Invocation.tool_use_id invocation)
        ~failure_effect_disposition:Tool_result.Effect_outcome_unknown
        result
  in
  execute ~plan ~run_id ~dispatch ?observe_node_result ()
;;
