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
  ; execution_id : Ids.Execution_id.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; schedule : Agent_core.Tool_contract.schedule
  ; result : Tool_result.result
  ; output_validation_error : Keeper_tool_plan.execution_error option
  ; tool_use_id : string
  ; failure_effect_disposition : Tool_result.failure_effect_disposition option
  ; deferred_kind : Keeper_tool_execution.deferred_kind option
  ; result_bytes : int
  ; truncated_to : int option
  }

type dispatch_result =
  { result : Tool_result.result
  ; failure_effect_disposition : Tool_result.failure_effect_disposition option
  ; deferred_kind : Keeper_tool_execution.deferred_kind option
  ; result_bytes : int option
  ; truncated_to : int option
  }

(* TEL-OK: pure smart constructor for the [dispatch_result] record above; it
   performs no action and emits no effect, so there is nothing to instrument. *)
let dispatch_result
      ?failure_effect_disposition
      ?deferred_kind
      ?result_bytes
      ?truncated_to
      result
  =
  { result
  ; failure_effect_disposition
  ; deferred_kind
  ; result_bytes
  ; truncated_to
  }
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
  tool_use_id:string
  -> node:Keeper_tool_plan.node
  -> descriptor:Keeper_tool_descriptor.t
  -> schedule:Agent_core.Tool_contract.schedule
  -> input:Yojson.Safe.t
  -> dispatch_result

type node_settlement =
  { result : node_result option
  ; output : Keeper_tool_plan.output option
  ; cause : cause option
  }

type wave_outcome =
  | Wave_settled of node_settlement * int
  (* A settled node carries its completion ticket: a global sequence number
     taken when the node finished dispatching. *)
  | Wave_skipped

(* Readers-writer gate for one plan run: concurrent nodes hold the shared
   side together while a serial or terminal node holds the exclusive side
   alone. Waiting fibers suspend on a condition instead of spinning, and new
   shared arrivals queue behind a waiting writer so the writer cannot starve.
   The gate is local to one execution; once the run aborts it is dropped. *)
module Exclusive_gate = struct
  type t =
    { mutex : Eio.Mutex.t
    ; changed : Eio.Condition.t
    ; mutable readers : int
    ; mutable writer : bool
    ; mutable waiting_writers : int
    }

  let create () =
    { mutex = Eio.Mutex.create ()
    ; changed = Eio.Condition.create ()
    ; readers = 0
    ; writer = false
    ; waiting_writers = 0
    }
  ;;

  let acquire_shared gate =
    Eio.Mutex.use_rw ~protect:false gate.mutex (fun () ->
      while gate.writer || gate.waiting_writers > 0 do
        Eio.Condition.await gate.changed gate.mutex
      done;
      gate.readers <- gate.readers + 1)
  ;;

  let release_shared gate =
    let underflow =
      Eio.Mutex.use_rw ~protect:false gate.mutex (fun () ->
        gate.readers <- gate.readers - 1;
        if gate.readers = 0 then Eio.Condition.broadcast gate.changed;
        gate.readers < 0)
    in
    if underflow then invalid_arg "tool plan gate released without a reader"
  ;;

  let acquire_exclusive gate =
    Eio.Mutex.use_rw ~protect:false gate.mutex (fun () ->
      gate.waiting_writers <- gate.waiting_writers + 1;
      (try
         while gate.writer || gate.readers > 0 do
           Eio.Condition.await gate.changed gate.mutex
         done;
         gate.writer <- true;
         gate.waiting_writers <- gate.waiting_writers - 1
       with
       | Eio.Cancel.Cancelled _ as exn ->
         gate.waiting_writers <- gate.waiting_writers - 1;
         Eio.Condition.broadcast gate.changed;
         raise exn))
  ;;

  let release_exclusive gate =
    let released_without_writer =
      Eio.Mutex.use_rw ~protect:false gate.mutex (fun () ->
        let missing = not gate.writer in
        gate.writer <- false;
        Eio.Condition.broadcast gate.changed;
        missing)
    in
    if released_without_writer
    then invalid_arg "tool plan gate released without a writer"
  ;;
end

let execute_one
      ~plan
      ~run_id
      ~prepared_inputs
      ~outputs
      ~tool_use_id_for_node
      ~dispatch
      ?observe_node_result
      scheduled
  =
  let node = scheduled.node in
  let node_id = node.Keeper_tool_plan.id in
  let plan_failure error =
    { result = None
    ; output = None
    ; cause = Some (Plan_execution_failed { node_id; schedule = scheduled.schedule; error })
    }
  in
  let input =
    match
      List.find_map
        (fun (id, prepared) ->
           if Keeper_tool_plan.Node_id.equal id node_id then Some prepared else None)
        prepared_inputs
    with
    | Some (Keeper_tool_plan.Checked_before_run input) -> Ok input
    | Some Keeper_tool_plan.Checked_when_node_runs ->
      Keeper_tool_plan.resolve_input
        plan
        ~run_id
        ~node_id
        ~lookup:(fun dependency ->
          List.find_map
            (fun (id, output) ->
               if Keeper_tool_plan.Node_id.equal id dependency then Some output else None)
            outputs)
    | None -> Error (Keeper_tool_plan.Unknown_node_id node_id)
  in
  match input with
  | Error error -> plan_failure error
  | Ok input ->
    (* The executor owns both occurrence identities. Mint them before entering
       dispatch so success, Deferred/Failed settlement, and the exception
       wrapper all project the exact same non-optional join key. *)
    let execution_id = Ids.Execution_id.generate () in
    let tool_use_id = tool_use_id_for_node ~execution_id node in
    let start_time = Tool_timing.start () in
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
             ~tool_use_id
             ~node
             ~descriptor:scheduled.descriptor
             ~schedule:scheduled.schedule
             ~input)
    in
    let result_bytes =
      Option.value
        ~default:(String.length (Tool_result.message result.result))
        result.result_bytes
    in
    let node_result =
      { node_id
      ; execution_id
      ; tool_name = node.tool_name
      ; input
      ; schedule = scheduled.schedule
      ; result = result.result
      ; output_validation_error = None
      ; tool_use_id
      ; failure_effect_disposition = result.failure_effect_disposition
      ; deferred_kind = result.deferred_kind
      ; result_bytes
      ; truncated_to = result.truncated_to
      }
    in
    let output, cause, output_validation_error =
      match result.result with
      | Tool_result.Deferred _ | Tool_result.Failed _ ->
        None, Some (Tool_did_not_complete node_result), None
      | Tool_result.Completed _ ->
        match scheduled.descriptor.Keeper_tool_descriptor.composable_output with
        | Keeper_tool_descriptor.Opaque_output -> None, None, None
        | Keeper_tool_descriptor.Json_output _ ->
          match Keeper_tool_plan.validate_output plan ~run_id ~node_id
                  (Tool_result.data result.result) with
          | Ok output -> Some output, None, None
          | Error error ->
            None,
            Some (Plan_execution_failed { node_id; schedule = scheduled.schedule; error }),
            Some error
    in
    let node_result = { node_result with output_validation_error } in
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
    match observation_error with
    | Some detail ->
      { result = Some node_result; output = None
      ; cause = Some (Node_observation_failed { node = node_result; detail }) }
    | None -> { result = Some node_result; output; cause }

;;

let execute_with_tool_use_id
      ~plan
      ~run_id
      ~tool_use_id_for_node
      ~dispatch
      ?observe_node_result
      ()
  =
  let node_effect_disposition (result : node_result) =
    match result.result with
    | Tool_result.Deferred _ | Tool_result.Failed _ ->
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
  (* Dynamic ready-wave runner: every node owns one fiber that starts when all
     of its dependencies have settled, instead of waiting for a static batch
     barrier. Serial and terminal nodes additionally follow the static
     schedule order and run alone behind [Exclusive_gate]. A node whose
     dependency failed or was skipped never dispatches; under [Fail_fast] no
     new node dispatches once any node is blocked, while under
     [Continue_independent] only the failed branch's descendants are blocked.
     Settled results are reported in canonical plan order and the cause is
     the lowest planned index, matching the static runner's contract. *)
  let run_wave ~prepared_inputs batches =
    let policy = Keeper_tool_plan.branch_failure_policy plan in
    let nodes = Keeper_tool_plan.nodes plan in
    let scheduled_nodes =
      List.concat_map
        (fun batch ->
          match batch with
          | Serial_batch scheduled -> [ scheduled ]
          | Concurrent_batch scheduled -> scheduled)
        batches
    in
    let find_scheduled node_id =
      match
        List.find_opt
          (fun (scheduled : scheduled_node) ->
            Keeper_tool_plan.Node_id.equal scheduled.node.Keeper_tool_plan.id node_id)
          scheduled_nodes
      with
      | Some scheduled -> scheduled
      | None ->
        invalid_arg
          (Printf.sprintf
             "validated composition plan lost the schedule of node %s"
             (Keeper_tool_plan.Node_id.to_string node_id))
    in
    let serial_chain =
      List.filter_map
        (fun batch ->
          match batch with
          | Serial_batch scheduled -> Some scheduled.node.Keeper_tool_plan.id
          | Concurrent_batch _ -> None)
        batches
    in
    let serial_predecessor node_id =
      let rec previous predecessor = function
        | [] -> None
        | candidate :: rest ->
          if Keeper_tool_plan.Node_id.equal candidate node_id
          then predecessor
          else previous (Some candidate) rest
      in
      previous None serial_chain
    in
    let outcomes =
      List.map
        (fun node ->
          let promise, resolve = Eio.Promise.create () in
          (node.Keeper_tool_plan.id, promise, resolve))
        nodes
    in
    let find_outcome node_id =
      match
        List.find_opt (fun (id, _, _) -> Keeper_tool_plan.Node_id.equal id node_id) outcomes
      with
      | Some (_, promise, resolve) -> (promise, resolve)
      | None ->
        invalid_arg
          (Printf.sprintf
             "validated composition plan lost the wave outcome of node %s"
             (Keeper_tool_plan.Node_id.to_string node_id))
    in
    let blocked = Atomic.make [] in
    let failures : (Keeper_tool_plan.Node_id.t * int) list Atomic.t = Atomic.make [] in
    let tick = Atomic.make 0 in
    let is_blocked id =
      List.exists (Keeper_tool_plan.Node_id.equal id) (Atomic.get blocked)
    in
    let mark_blocked id =
      let rec loop () =
        let current = Atomic.get blocked in
        if List.exists (Keeper_tool_plan.Node_id.equal id) current
        then ()
        else if Atomic.compare_and_set blocked current (id :: current)
        then ()
        else loop ()
      in
      loop ()
    in
    let mark_failed id ticket =
      let rec loop () =
        let current = Atomic.get failures in
        if List.exists (fun (failed, _) -> Keeper_tool_plan.Node_id.equal failed id) current
        then ()
        else if Atomic.compare_and_set failures current ((id, ticket) :: current)
        then ()
        else loop ()
      in
      loop ()
    in
    let gate = Exclusive_gate.create () in
    let run_node node =
      let node_id = node.Keeper_tool_plan.id in
      let scheduled = find_scheduled node_id in
      let exclusive =
        match scheduled.schedule.execution_mode with
        | Agent_core.Tool_contract.Serial -> true
        | Agent_core.Tool_contract.Concurrent -> false
      in
      let dependency_outcomes =
        List.map
          (fun dependency ->
            let promise, _ = find_outcome dependency in
            (dependency, Eio.Promise.await promise))
          (Keeper_tool_plan.dependencies node)
      in
      (match serial_predecessor node_id with
       | None -> ()
       | Some predecessor ->
         let promise, _ = find_outcome predecessor in
         ignore (Eio.Promise.await promise));
      let skip () =
        mark_blocked node_id;
        let _, resolve = find_outcome node_id in
        Eio.Promise.resolve resolve Wave_skipped
      in
      (* A node commits once every dependency has settled: its commit ticket is
         the latest dependency completion. Under [Fail_fast] a node stops only
         when a failure completed before that commit, so siblings that were
         already unblocked still settle exactly like one static batch. Later
         or concurrent failures never retroactively stop a committed node. *)
      let commit_ticket, dependency_blocked =
        List.fold_left
          (fun (latest, blocked_found) (dependency, outcome) ->
            match outcome with
            | Wave_skipped -> (latest, true)
            | Wave_settled (_, ticket) ->
              ((if ticket > latest then ticket else latest), blocked_found || is_blocked dependency))
          (-1, false)
          dependency_outcomes
      in
      let failure_before_ready =
        List.exists
          (fun (_, failure_ticket) -> failure_ticket < commit_ticket)
          (Atomic.get failures)
      in
      let halted =
        match policy with
        | Keeper_tool_plan.Fail_fast -> failure_before_ready
        | Keeper_tool_plan.Continue_independent -> false
      in
      if dependency_blocked || halted
      then skip ()
      else (
        if exclusive
        then Exclusive_gate.acquire_exclusive gate
        else Exclusive_gate.acquire_shared gate;
        let release () =
          if exclusive
          then Exclusive_gate.release_exclusive gate
          else Exclusive_gate.release_shared gate
        in
        let halted_after_gate =
          match policy with
          | Keeper_tool_plan.Fail_fast ->
            List.exists
              (fun (_, failure_ticket) -> failure_ticket < commit_ticket)
              (Atomic.get failures)
          | Keeper_tool_plan.Continue_independent -> false
        in
        if halted_after_gate
        then (
          release ();
          skip ())
        else (
          let outputs =
            List.filter_map
              (fun (dependency, outcome) ->
                match outcome with
                | Wave_settled (settlement, _) ->
                  Option.map
                    (fun output -> (dependency, output))
                    settlement.output
                | Wave_skipped -> None)
              dependency_outcomes
          in
          let settlement =
            execute_one
              ~plan
              ~run_id
              ~prepared_inputs
              ~outputs
              ~tool_use_id_for_node
              ~dispatch
              ?observe_node_result
              scheduled
          in
          let ticket = Atomic.fetch_and_add tick 1 in
          release ();
          (match settlement.cause with
           | Some _ ->
             mark_blocked node_id;
             mark_failed node_id ticket
           | None -> ());
          let _, resolve = find_outcome node_id in
          Eio.Promise.resolve resolve (Wave_settled (settlement, ticket))))
    in
    Eio.Fiber.all (List.map (fun node () -> run_node node) nodes);
    let wave_results =
      List.map
        (fun node ->
          let promise, _ = find_outcome node.Keeper_tool_plan.id in
          (match Eio.Promise.peek promise with
           | Some outcome -> outcome
           | None ->
             invalid_arg
               (Printf.sprintf
                  "tool plan wave finished without settling node %s"
                  (Keeper_tool_plan.Node_id.to_string node.Keeper_tool_plan.id))))
        nodes
    in
    let settled =
      List.filter_map
        (fun outcome ->
          match outcome with
          | Wave_settled (settlement, _) -> settlement.result
          | Wave_skipped -> None)
        wave_results
    in
    let causes =
      List.filter_map
        (fun (node, outcome) ->
          match outcome with
          | Wave_settled (settlement, _) ->
            (match settlement.cause with
             | Some cause ->
               let scheduled = find_scheduled node.Keeper_tool_plan.id in
               Some (scheduled.schedule.planned_index, cause)
             | None -> None)
          | Wave_skipped -> None)
        (List.combine nodes wave_results)
    in
    let ordered_causes =
      List.sort (fun (left, _) (right, _) -> Int.compare left right) causes
    in
    (match ordered_causes with
     | [] -> Ok settled
     | (_, cause) :: _ ->
       Error { settled; cause; effect_disposition = aggregate_effect_disposition settled })
  in
  let batches = schedule plan in
  match Keeper_tool_plan.prepare_inputs plan with
  | Ok prepared_inputs -> run_wave ~prepared_inputs batches
  | Error (node_id, error) ->
    let scheduled =
      List.find_map
        (fun batch ->
           let scheduled_nodes =
             match batch with
             | Serial_batch scheduled -> [ scheduled ]
             | Concurrent_batch scheduled -> scheduled
           in
           List.find_opt
             (fun (scheduled : scheduled_node) ->
                Keeper_tool_plan.Node_id.equal scheduled.node.Keeper_tool_plan.id node_id)
             scheduled_nodes)
        batches
    in
    (match scheduled with
     | Some (scheduled : scheduled_node) ->
       Error
         { settled = []
         ; cause =
             Plan_execution_failed { node_id; schedule = scheduled.schedule; error }
         ; effect_disposition = Tool_result.Proven_pre_effect
         }
     | None ->
       invalid_arg
         (Printf.sprintf
            "validated composition plan lost the schedule of node %s"
            (Keeper_tool_plan.Node_id.to_string node_id)))
;;

(* TEL-OK: forwards to [execute_with_tool_use_id] below; no new effect
   originates here, so there is nothing local to instrument. *)
let execute ~plan ~run_id ~dispatch ?observe_node_result () =
  let tool_use_id_for_node ~execution_id _node =
    "composition-node:" ^ Ids.Execution_id.to_string execution_id
  in
  execute_with_tool_use_id
    ~plan
    ~run_id
    ~tool_use_id_for_node
    ~dispatch
    ?observe_node_result
    ()
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

let execute_keeper_with_authority
      ~plan
      ~run_id
      ?composition_run_id
      ~parent_invocation
      ~config
      ~meta
      ~capability_authority
      ~publication_recovery
      ~ctx_snapshot
      ~keeper_turn_id
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
  (* TEL-OK: [handler] below is Keeper_tools_agent_core_handler, which
     already records telemetry (Otel_metric_store.inc_counter). *)
  let dispatch ~tool_use_id ~(node : Keeper_tool_plan.node) ~descriptor ~schedule ~input =
    let terminal_on_completed, terminal_on_failed =
      match descriptor.Keeper_tool_descriptor.execution with
      | Keeper_tool_descriptor.Terminal -> on_completed, on_failed
      | Keeper_tool_descriptor.Ordinary
          (Keeper_tool_descriptor.Serial | Keeper_tool_descriptor.Concurrent) ->
        None, None
    in
    let execution_evidence = ref None in
    let make_handler =
      match capability_authority with
      | Keeper_tool_runtime.Frozen_surface capability_surface ->
        Keeper_tools_agent_core_handler.make_keeper_tool_handler
          ~capability_surface
      | Keeper_tool_runtime.Compatibility_meta ->
        Keeper_tools_agent_core_handler.make_keeper_tool_handler_from_meta
    in
    let handler =
      make_handler
        ~name:descriptor.internal_name
        ~descriptor
        ~model_name:node.tool_name
        ~input_schema:descriptor.input_schema
        ~config
        ~meta
        ~publication_recovery
        ~ctx_snapshot
        ~keeper_turn_id
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
        ~tool_use_id
        ~turn:(Agent_core.Tool_contract.Invocation.turn parent_invocation)
        ~schedule
        ~completion:Agent_core.Tool_contract.Continue_after_success
    in
    let result = handler ~agent_core_invocation:invocation input in
    let original_bytes, truncated_to =
      Keeper_tool_call_log.consume_truncation_info ~invocation ()
    in
    let result_bytes =
      if original_bytes > 0
      then original_bytes
      else String.length (Tool_result.message result)
    in
    match !execution_evidence with
    | Some (failure_effect_disposition, deferred_kind) ->
      { result
      ; failure_effect_disposition
      ; deferred_kind
      ; result_bytes = Some result_bytes
      ; truncated_to
      }
    | None ->
      dispatch_result
        ~failure_effect_disposition:Tool_result.Effect_outcome_unknown
        ~result_bytes
        ?truncated_to
        result
  in
  let tool_use_id_for_node ~execution_id:_ node =
    nested_tool_use_id ~composition_run_id parent_invocation node.Keeper_tool_plan.id
  in
  execute_with_tool_use_id
    ~plan
    ~run_id
    ~tool_use_id_for_node
    ~dispatch
    ?observe_node_result
    ()
;;

let execute_keeper ~capability_surface =
  execute_keeper_with_authority
    ~capability_authority:
      (Keeper_tool_runtime.Frozen_surface capability_surface)
;;

module Compatibility = struct
  let execute_keeper =
    execute_keeper_with_authority
      ~capability_authority:Keeper_tool_runtime.Compatibility_meta
  ;;
end
