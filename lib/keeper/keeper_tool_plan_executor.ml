module Node_map = Map.Make (Keeper_tool_plan.Node_id)
module Node_set = Set.Make (Keeper_tool_plan.Node_id)

type scheduled_node =
  { node : Keeper_tool_plan.node
  ; contract : Keeper_tool_plan.contract
  ; schedule : Agent_core.Tool_contract.schedule
  }

type batch =
  | Serial_batch of scheduled_node
  | Concurrent_batch of scheduled_node list

type unscheduled_batch =
  | Unscheduled_serial of Keeper_tool_plan.node * Keeper_tool_plan.contract
  | Unscheduled_concurrent of (Keeper_tool_plan.node * Keeper_tool_plan.contract) list

type resource_ordering =
  | Descriptor_order
  | Prepared_order of Keeper_tool_plan.Node_id.t list Node_map.t
  | Ready_order

let contract_exn plan node =
  match Keeper_tool_plan.contract plan node.Keeper_tool_plan.id with
  | Some contract -> contract
  | None ->
    invalid_arg
      (Printf.sprintf
         "validated composition plan lost contract for node %s"
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
      let contract = contract_exn plan node in
      (match contract.Keeper_tool_plan.execution with
       | Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Concurrent ->
         build batches ((node, contract) :: concurrent) rest
       | Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Serial
       | Keeper_tool_descriptor.Terminal ->
         let batches = flush_concurrent batches concurrent in
         build (Unscheduled_serial (node, contract) :: batches) [] rest)
  in
  build [] [] nodes
;;

let predecessors dependencies node_id =
  match Node_map.find_opt node_id dependencies with
  | Some predecessors -> predecessors
  | None -> invalid_arg "prepared Inline file lost its resource ordering"
;;

let prepared_layer plan dependencies nodes =
  (* Lists retain the original partition and group order. This layer-local set
     answers membership only; a following wave removes the ready partition. *)
  let pending_ids = List.fold_left (fun ids (node : Keeper_tool_plan.node) ->
      Node_set.add node.id ids) Node_set.empty nodes in
  let rec waves pending_ids = function
    | [] -> []
    | pending ->
      let ready, waiting = List.partition (fun (node : Keeper_tool_plan.node) ->
        let earlier = predecessors dependencies node.id in
        not (List.exists (fun predecessor -> Node_set.mem predecessor pending_ids) earlier)) pending in
      if ready = [] then invalid_arg "prepared Inline file resource ordering contains a cycle";
      let waiting_ids = match waiting with
        | [] -> Node_set.empty
        | _ :: _ -> List.fold_left (fun ids (node : Keeper_tool_plan.node) ->
            Node_set.remove node.id ids) pending_ids ready in
      Unscheduled_concurrent (List.map (fun node -> node, contract_exn plan node) ready)
      :: waves waiting_ids waiting
  in
  waves pending_ids nodes
;;

let schedule_layers ~resource_ordering plan layers =
  let planned_indexes =
    Keeper_tool_plan.nodes plan
    |> List.mapi (fun index node -> node.Keeper_tool_plan.id, index)
    |> Node_map.of_list
  in
  let planned_index node =
    match Node_map.find_opt node.Keeper_tool_plan.id planned_indexes with
    | Some index -> index
    | None -> invalid_arg "validated composition plan lost a canonical node"
  in
  layers
  |> List.concat_map (match resource_ordering with
    | Descriptor_order -> unscheduled_layer plan
    | Prepared_order dependencies -> prepared_layer plan dependencies
    | Ready_order -> (function
        | [] -> []
        | (_ :: _ as nodes) ->
          (* Ready's original static group is concurrent. Its live bindings
             supply actual resource/exclusive ordering in the runner below. *)
          [Unscheduled_concurrent (List.map (fun node -> node, contract_exn plan node) nodes)]))
  |> List.mapi (fun batch_index batch ->
    let scheduled_node ~execution_mode ~batch_size (node, contract) =
      { node
      ; contract
      ; schedule =
          { Agent_core.Tool_contract.planned_index = planned_index node
          ; batch_index
          ; batch_size
          ; execution_mode
          }
      }
    in
    match batch with
    | Unscheduled_serial (node, contract) ->
      Serial_batch (scheduled_node ~execution_mode:Agent_core.Tool_contract.Serial
        ~batch_size:1 (node, contract))
    | Unscheduled_concurrent nodes ->
      let batch_size = List.length nodes in
      Concurrent_batch (List.map
        (scheduled_node ~execution_mode:Agent_core.Tool_contract.Concurrent ~batch_size) nodes))
;;

let schedule plan = schedule_layers ~resource_ordering:Descriptor_order plan
    (Keeper_tool_plan.dependency_layers plan)
;;

let outer_completion plan =
  if
    List.exists
      (fun node ->
         match Keeper_tool_plan.contract plan node.Keeper_tool_plan.id with
         | Some { Keeper_tool_plan.execution = Keeper_tool_descriptor.Terminal; _ } ->
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

type node_execution_origin = Keeper_skill_composition_evidence.Node_execution_origin.t =
  | Fresh_dispatch
  | Retained_completion
  | Dispatch_refused

let node_execution_origin_to_string =
  Keeper_skill_composition_evidence.Node_execution_origin.to_string
;;

type node_result =
  { node_id : Keeper_tool_plan.Node_id.t
  ; execution_id : Ids.Execution_id.t
  ; physical_execution_id : Ids.Execution_id.t option
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; schedule : Agent_core.Tool_contract.schedule
  ; result : Tool_result.result
  ; output_validation_error : Keeper_tool_plan.execution_error option
  ; tool_use_id : string
  ; execution_origin : node_execution_origin
  ; failure_effect_disposition : Tool_result.failure_effect_disposition option
  ; deferred_kind : Keeper_tool_execution.deferred_kind option
  ; result_bytes : int
  ; truncated_to : int option
  }

type dispatch_result =
  { result : Tool_result.result
  ; physical_execution_id : Ids.Execution_id.t option
  ; failure_effect_disposition : Tool_result.failure_effect_disposition option
  ; deferred_kind : Keeper_tool_execution.deferred_kind option
  ; result_bytes : int option
  ; truncated_to : int option
  }

type admission_rejection =
  { detail : string
  ; data : Yojson.Safe.t
  }

(* TEL-OK: pure smart constructor for the [dispatch_result] record above; it
   performs no action and emits no effect, so there is nothing to instrument. *)
let dispatch_result
      ?physical_execution_id
      ?failure_effect_disposition
      ?deferred_kind
      ?result_bytes
      ?truncated_to
      result
  =
  { result
  ; physical_execution_id
  ; failure_effect_disposition
  ; deferred_kind
  ; result_bytes
  ; truncated_to
  }
;;

type cause =
  | Run_journal_rejected of Keeper_tool_execution_journal.error
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
  ; additional_causes : cause list
  ; effect_disposition : Tool_result.failure_effect_disposition
  }

let failure_causes failure = failure.cause :: failure.additional_causes

type dispatch =
  ?launch_replay:Keeper_tool_execution_journal.recheck_launch
  -> tool_use_id:string
  -> node:Keeper_tool_plan.node
  -> descriptor:Keeper_tool_descriptor.t
  -> schedule:Agent_core.Tool_contract.schedule
  -> input:Yojson.Safe.t
  -> unit
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

type compiled_dispatch =
  attempt:Keeper_tool_execution_journal.attempt ->
  target:Keeper_tool_plan.execution_target ->
  tool_use_id:string -> node:Keeper_tool_plan.node ->
  schedule:Agent_core.Tool_contract.schedule -> input:Yojson.Safe.t -> dispatch_result

let resolve_node_input ~plan ~run_id ~node_id ~prepared_inputs ~outputs =
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
;;

let execute_one
      ~plan
      ~run_id
      ~input
      ~tool_use_id_for_node
      ~dispatch
      ?launch_invocation_of
      ?admit_node
      ?dispatch_compiled
      ?journal
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
  match input with
  | Error error -> plan_failure error
  | Ok input ->
    (* The executor owns both occurrence identities. Mint them before entering
       dispatch so success, Deferred/Failed settlement, and the exception
       wrapper all project the exact same non-optional join key. *)
    let execution_id = Ids.Execution_id.generate () in
    let tool_use_id = tool_use_id_for_node ~execution_id node in
    let start_time = Tool_timing.start () in
    let journal_failure error =
      dispatch_result
        ~failure_effect_disposition:Tool_result.Effect_outcome_unknown
        (Tool_result.make_err
           ~class_:(Keeper_tool_execution_journal.failure_class error)
           ~effect_disposition:Tool_result.Effect_outcome_unknown
           ~tool_name:node.tool_name ~start_time
           ~data:(Keeper_tool_execution_journal.error_to_json error)
           (Keeper_tool_execution_journal.error_to_string error))
    in
    (* A launch leaf in a journaled run must stay re-provable after an
       interruption. Refuse the dispatch before any durable attempt when its
       exact invocation identity cannot be derived: launching without it could
       never return to the same owned job. *)
    let launch_identity_refusal () =
      dispatch_result
        ~failure_effect_disposition:Tool_result.Proven_pre_effect
        (Tool_result.make_err
           ~class_:Tool_result.Policy_rejection
           ~effect_disposition:Tool_result.Proven_pre_effect
           ~tool_name:node.tool_name ~start_time
           ~data:(`Assoc
             [ "kind", `String "launch_invocation_incomplete"
             ; "node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
             ; "tool_name", `String node.tool_name ])
           "composition launch leaf lacks complete invocation identity (trace_id, turn_ref, tool_use_id); \
            refusing dispatch instead of launching a job that interruption cannot re-prove")
    in
    let dispatch_fresh ?attempt ~tool_use_id ?launch_replay () =
      let refuse detail =
        dispatch_result ~failure_effect_disposition:Tool_result.Proven_pre_effect
          (Tool_result.make_err ~class_:Tool_result.Workflow_rejection
            ~effect_disposition:Tool_result.Proven_pre_effect ~tool_name:node.tool_name
            ~start_time detail) in
      Cancel_safe.protect
        ~on_exn:(fun exn ->
          dispatch_result
            ~failure_effect_disposition:Tool_result.Effect_outcome_unknown
            (Tool_result.make_err_of_exn
               ~class_:Tool_result.Runtime_failure
               ~tool_name:node.tool_name ~start_time exn))
        (fun () ->
          match (match admit_node with None -> Ok () | Some admit -> admit ~node) with
          | Error rejection ->
            dispatch_result ~failure_effect_disposition:Tool_result.Proven_pre_effect
              (Tool_result.make_err ~tool_name:node.tool_name ~class_:Tool_result.Runtime_failure
                ~effect_disposition:Tool_result.Proven_pre_effect ~start_time
                ~data:rejection.data rejection.detail)
          | Ok () ->
          match scheduled.contract.target with
          | Keeper_tool_plan.Descriptor_target descriptor ->
            dispatch ?launch_replay ~tool_use_id ~node ~descriptor ~schedule:scheduled.schedule ~input ()
          | Keeper_tool_plan.Child_arguments _ ->
            dispatch_result (Tool_result.make_ok ~tool_name:node.tool_name ~start_time ~data:input ())
          | (Keeper_tool_plan.Child_submission _ | Keeper_tool_plan.Child_result _) as target ->
            match attempt,dispatch_compiled with
            | Some attempt,Some dispatch ->
              dispatch ~attempt ~target ~tool_use_id ~node ~schedule:scheduled.schedule ~input
            | None,_ -> refuse "Compiled child execution requires the canonical parent journal occurrence."
            | Some _,None -> refuse "Compiled child execution requires the original child producer authority.")
    in
    let execution_id, tool_use_id, execution_origin, result, journal_error =
      match journal with
      | None -> execution_id, tool_use_id, Fresh_dispatch, dispatch_fresh ~tool_use_id (), None
      | Some worker ->
        (match Keeper_tool_execution_journal.lookup worker
                 ~node_id ~tool_name:node.tool_name ~input with
         | Error error ->
           execution_id, tool_use_id, Dispatch_refused, journal_failure error, None
         | Ok (Keeper_tool_execution_journal.Reuse_completed stored) ->
           stored.execution_id, stored.tool_use_id, Retained_completion,
           dispatch_result ~result_bytes:stored.result_bytes
             ?truncated_to:stored.truncated_to stored.result, None
         | Ok ((Keeper_tool_execution_journal.Dispatch
              | Keeper_tool_execution_journal.Recheck_result _
              | Keeper_tool_execution_journal.Recheck_launch _
              | Keeper_tool_execution_journal.Recheck_child_submission _) as replay) ->
           let execution_id, tool_use_id = match replay with
             | Keeper_tool_execution_journal.Recheck_result stored
             | Keeper_tool_execution_journal.Recheck_child_submission stored ->
                 stored.execution_id, stored.tool_use_id
             | Keeper_tool_execution_journal.Recheck_launch stored ->
                 stored.execution_id, stored.tool_use_id
             | Keeper_tool_execution_journal.Dispatch
             | Keeper_tool_execution_journal.Reuse_completed _ -> execution_id, tool_use_id in
           let launch_leaf = match scheduled.contract.target with
             | Keeper_tool_plan.Descriptor_target descriptor ->
               Keeper_tool_descriptor.prepared_leaf_admission descriptor
               = Keeper_tool_descriptor.Owned_job_launch_leaf
             | Keeper_tool_plan.Child_arguments _ | Keeper_tool_plan.Child_submission _
             | Keeper_tool_plan.Child_result _ -> false in
           let launch_invocation, launch_replay = match replay with
             | Keeper_tool_execution_journal.Recheck_launch stored ->
                 Some stored.invocation, Some stored
             | Keeper_tool_execution_journal.Dispatch
             | Keeper_tool_execution_journal.Recheck_result _
             | Keeper_tool_execution_journal.Recheck_child_submission _
             | Keeper_tool_execution_journal.Reuse_completed _ ->
                 if launch_leaf then
                   (match launch_invocation_of with
                    | Some derive -> derive (), None
                    | None -> None, None)
                 else None, None in
           (match launch_leaf, launch_invocation with
            | true, None ->
                execution_id, tool_use_id, Dispatch_refused, launch_identity_refusal (), None
            | _ ->
           let readonly =
             Keeper_tool_plan.readonly_for_input plan ~node_id ~input
             = Some true
           in
           match Keeper_tool_execution_journal.begin_attempt worker
                   ~node_id ~tool_name:node.tool_name ~input
                   ~execution_id ~tool_use_id ~readonly ?launch_invocation () with
           | Error error ->
             execution_id, tool_use_id, Dispatch_refused, journal_failure error, None
           | Ok attempt ->
             let result = dispatch_fresh ~attempt ~tool_use_id ?launch_replay () in
             let result_bytes = match result.result_bytes with
               | Some bytes -> bytes
               | None -> String.length (Tool_result.message result.result)
             in
             let journal_error =
               match Keeper_tool_execution_journal.settle_attempt
                       ?failure_effect_disposition:result.failure_effect_disposition
                       ?deferred_kind:result.deferred_kind
                       attempt
                       ~result:result.result ~result_bytes
                       ~truncated_to:result.truncated_to with
               | Ok () -> None
               | Error error -> Some (Keeper_tool_execution_journal.error_to_string error)
             in
             execution_id, tool_use_id, Fresh_dispatch, result, journal_error))
    in
    let result_bytes =
      match result.result_bytes with
      | Some bytes -> bytes
      | None -> String.length (Tool_result.message result.result)
    in
    let node_result =
      { node_id
      ; execution_id
      ; physical_execution_id = result.physical_execution_id
      ; tool_name = node.tool_name
      ; input
      ; schedule = scheduled.schedule
      ; result = result.result
      ; output_validation_error = None
      ; tool_use_id
      ; execution_origin
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
        match scheduled.contract.composable_output with
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
      match journal_error, execution_origin, observe_node_result with
      | Some detail, _, _ -> Some detail
      | None, Retained_completion, _ -> None
      | None, (Fresh_dispatch | Dispatch_refused), None -> None
      | None, (Fresh_dispatch | Dispatch_refused), Some observe ->
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

type ready_file_dispatch =
  { files : Keeper_prepared_inline_files.Ready.t
  ; dispatch : Keeper_prepared_inline_files.Ready.binding -> dispatch
  }

let execute_with_tool_use_id
      ~plan
      ~run_id
      ~tool_use_id_for_node
      ~dispatch
      ?prepared_files
      ?ready_files
      ?launch_invocation_of
      ?admit_node
      ?dispatch_compiled
      ?journal
      ?observe_node_result
      ()
  =
  (* Each preparation supplies its original immutable graph after checking
     plan identity. Share it with scheduling rather than rebuilding it after
     resource ordering. Ordinary execution still builds its own graph. Inputs
     still resolve per node; run bindings/resources/results are not cached here. *)
  let resource_ordering, dependency_layers = match ready_files with
    | None ->
      (match Option.bind prepared_files (Keeper_prepared_inline_files.resource_ordering ~plan) with
       | None -> Descriptor_order, Keeper_tool_plan.dependency_layers plan
       | Some ordering ->
         (* The exact producer supplies one row per validated original ID.
            Keep its predecessor lists unchanged for wave and outcome waits. *)
         Prepared_order (Node_map.of_list ordering.Keeper_prepared_inline_files.predecessors),
         ordering.dependency_layers)
    | Some ready ->
      if not (Keeper_prepared_inline_files.Ready.plan ready.files == plan) then
        invalid_arg "ready Inline files belong to a different plan";
      Ready_order, Keeper_prepared_inline_files.Ready.dependency_layers ready.files in
  let node_effect_disposition (result : node_result) =
    match result.result with
    | Tool_result.Deferred _ | Tool_result.Failed _ ->
      Option.value
        ~default:Tool_result.Effect_outcome_unknown
        result.failure_effect_disposition
    | Tool_result.Completed _ ->
      (match Keeper_tool_plan.readonly_for_input plan ~node_id:result.node_id ~input:result.input with
       | Some true -> Tool_result.Proven_pre_effect
       | Some false | None -> Tool_result.Proven_post_effect)
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
     barrier. Ordinary serial and terminal nodes additionally follow the static
     schedule order and run alone behind [Exclusive_gate]. Exact prepared
     Read/Edit/Write leaves wait for conflicting resource owners and opaque
     ordinary barriers, retaining the original Serial success dependencies. A node whose
     dependency failed or was skipped never dispatches; under [Fail_fast] no
     new node dispatches once any node is blocked, while under
     [Continue_independent] only the failed branch's descendants are blocked.
     Settled results are reported in canonical plan order and the cause is
     the lowest planned index, matching the static runner's contract. *)
  let run_wave ~prepared_inputs batches =
    let policy = Keeper_tool_plan.branch_failure_policy plan in
    let nodes = Keeper_tool_plan.nodes plan in
    (* Indexes only refer to the original schedules and owner pairs below.
       The original lists still own iteration/order; promise cells are created
       once per node here, never on lookup or retained across executions. *)
    let scheduled_nodes =
      List.concat_map
        (fun batch ->
          match batch with
          | Serial_batch scheduled -> [ scheduled ]
          | Concurrent_batch scheduled -> scheduled)
        batches
      |> List.map (fun (scheduled : scheduled_node) -> scheduled.node.Keeper_tool_plan.id, scheduled)
      |> Node_map.of_list
    in
    let find_scheduled node_id =
      match Node_map.find_opt node_id scheduled_nodes with
      | Some scheduled -> scheduled
      | None ->
        invalid_arg
          (Printf.sprintf
             "validated composition plan lost the schedule of node %s"
             (Keeper_tool_plan.Node_id.to_string node_id))
    in
    (* Only Serial batches participate. An absent entry (ordinary concurrent
       work) and the first Serial entry both have no Serial predecessor. *)
    let _, serial_predecessors =
      List.fold_left
        (fun (previous, index) batch ->
          match batch with
          | Serial_batch scheduled ->
            let id = scheduled.node.Keeper_tool_plan.id in
            Some id, Node_map.add id previous index
          | Concurrent_batch _ -> previous, index)
        (None, Node_map.empty)
        batches
    in
    let serial_predecessor node_id =
      match Node_map.find_opt node_id serial_predecessors with
      | Some predecessor -> predecessor
      | None -> None
    in
    let ordering_predecessors node_id = match resource_ordering with
      | Prepared_order dependencies -> predecessors dependencies node_id
      | Descriptor_order -> Option.to_list (serial_predecessor node_id)
      | Ready_order -> []
    in
    let outcomes =
      List.map
        (fun node ->
          let promise, resolve = Eio.Promise.create () in
          node.Keeper_tool_plan.id, (promise, resolve))
        nodes
      |> Node_map.of_list
    in
    let find_outcome node_id =
      match Node_map.find_opt node_id outcomes with
      | Some owner -> owner
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
    let bindings = match ready_files with
      | None -> Node_map.empty
      | Some _ -> List.map (fun (node : Keeper_tool_plan.node) ->
          let promise, resolve = Eio.Promise.create () in node.id, (promise, resolve)) nodes
          |> Node_map.of_list in
    let ready_order = match ready_files with
      | None -> []
      | Some _ -> List.concat dependency_layers in
    (* Each stop is an original suffix of this invocation's immutable order,
       not a copied prefix or resource authority. Physical equality is local
       to traversal of that exact list; declaration order is not topological. *)
    let ready_stops =
      let rec index stops = function
        | [] -> stops
        | ((node : Keeper_tool_plan.node) :: rest as suffix) ->
            index (Node_map.add node.id suffix stops) rest in
      index Node_map.empty ready_order in
    let find_binding node_id =
      match Node_map.find_opt node_id bindings with
      | Some owner -> owner
      | None -> invalid_arg "ready Inline file lost its binding promise" in
    let filter_earlier node_id classify =
      let stop = match Node_map.find_opt node_id ready_stops with
        | Some suffix -> suffix
        | None -> invalid_arg "ready Inline file lost its topological position" in
      let[@tail_mod_cons] rec before remaining =
        if remaining == stop then []
        else match remaining with
          | [] -> invalid_arg "ready Inline file lost its topological prefix"
          | (node : Keeper_tool_plan.node) :: rest ->
              match classify node.id with
              | None -> before rest
              | Some result -> result :: before rest in
      before ready_order in
    let stopped = function
      | Wave_skipped -> true
      | Wave_settled (settlement, _) -> Option.is_some settlement.cause in
    let ordering_blocks outcomes = List.exists (fun (_,order,outcome) ->
      match order with
      | Keeper_prepared_inline_files.Ready.No_order -> false
      | Require_success -> stopped outcome
      | Wait_for_settlement ->
        match policy with
        | Keeper_tool_plan.Fail_fast -> stopped outcome
        | Keeper_tool_plan.Continue_independent -> false) outcomes in
    let run_node node =
      let node_id = node.Keeper_tool_plan.id in
      let scheduled = find_scheduled node_id in
      let dependency_outcomes = List.map (fun dependency ->
          let promise, _ = find_outcome dependency in
          dependency, Eio.Promise.await promise) (Keeper_tool_plan.dependencies node) in
      let publish_binding binding = match ready_files with
        | None -> ()
        | Some _ ->
          let promise, resolve = find_binding node_id in
          if Option.is_none (Eio.Promise.peek promise) then Eio.Promise.resolve resolve binding in
      let skip () =
        publish_binding None;
        mark_blocked node_id;
        let _, resolve = find_outcome node_id in
        Eio.Promise.resolve resolve Wave_skipped in
      if Option.is_some ready_files && List.exists (fun (_, outcome) -> stopped outcome) dependency_outcomes
      then skip ()
      else
      let outputs = List.filter_map (fun (dependency, outcome) -> match outcome with
          | Wave_settled (settlement, _) -> Option.map (fun output -> dependency, output) settlement.output
          | Wave_skipped -> None) dependency_outcomes in
      let input = resolve_node_input ~plan ~run_id ~node_id ~prepared_inputs ~outputs in
      (* An opaque predecessor may change physical file bindings. Wait for it
         before preparing a later file, not just before invoking its handler.
         Earlier topological nodes cannot depend on this unpublished binding. *)
      let preparation_outcomes = match ready_files,input with
        | Some ready,Ok _ -> List.filter_map (fun (earlier,order) ->
            match order with
            | Keeper_prepared_inline_files.Ready.No_order -> None
            | (Wait_for_settlement | Require_success) as order ->
                let promise,_ = find_outcome earlier in
                Some (earlier,order,Eio.Promise.await promise))
            (Keeper_prepared_inline_files.Ready.preparation_predecessors ready.files ~node)
        | None,_ | Some _,Error _ -> [] in
      if ordering_blocks preparation_outcomes then skip () else
      let binding = match ready_files, input with
        | Some ready, Ok input -> Some (Keeper_prepared_inline_files.Ready.bind ready.files ~node ~input)
        | None, _ | Some _, Error _ -> None in
      publish_binding binding;
      (* Publish resolved producer claims before waiting for earlier claims.
         Binding order is topological, so an earlier unresolved input cannot
         depend on this node. File conflicts and opaque ordering barriers wait
         for tool settlement with their separate failure requirements. *)
      let predecessors = match ready_files with
        | None -> List.map (fun id -> id, Keeper_prepared_inline_files.Ready.Require_success)
            (ordering_predecessors node_id)
        | Some _ -> filter_earlier node_id (fun earlier ->
            let promise, _ = find_binding earlier in
            match binding, Eio.Promise.await promise with
            | Some current, Some prior ->
                (match Keeper_prepared_inline_files.Ready.ordering prior current with
                 | Keeper_prepared_inline_files.Ready.No_order -> None
                 | (Wait_for_settlement | Require_success) as order -> Some (earlier,order))
            | None, _ | Some _, None -> None) in
      let ordered_outcomes = List.map (fun (predecessor,order) ->
          let promise, _ = find_outcome predecessor in
          predecessor, order, Eio.Promise.await promise) predecessors in
      let predecessor_outcomes = List.filter_map (fun (predecessor,order,outcome) ->
        match order with
        | Keeper_prepared_inline_files.Ready.Require_success -> Some (predecessor,outcome)
        | No_order | Wait_for_settlement -> None) ordered_outcomes in
      if ordering_blocks ordered_outcomes
      then skip ()
      else (
        let commit_ticket, dependency_blocked = List.fold_left
            (fun (latest, blocked_found) (dependency, outcome) -> match outcome with
              | Wave_skipped -> latest, true
              | Wave_settled (_, ticket) ->
                max ticket latest, blocked_found || is_blocked dependency)
            (-1, false)
            (dependency_outcomes @ (match resource_ordering with
              | Prepared_order _ | Ready_order -> predecessor_outcomes
              | Descriptor_order -> [])) in
        (* Soft barriers contribute observed settlement tickets to Fail_fast
           ordering, but are not producer/data dependencies. *)
        let commit_ticket = match ready_files with
          | None -> commit_ticket
          | Some _ -> List.fold_left (fun latest (_,_,outcome) -> match outcome with
              | Wave_skipped -> latest
              | Wave_settled (_,ticket) -> max latest ticket) commit_ticket ordered_outcomes in
        let halted () = match policy with
          | Keeper_tool_plan.Fail_fast -> List.exists
              (fun (_, failure_ticket) -> failure_ticket < commit_ticket) (Atomic.get failures)
          | Keeper_tool_plan.Continue_independent -> false in
        if dependency_blocked || halted () then skip ()
        else (
          let exclusive = match ready_files, binding with
            | Some _, Some binding -> Keeper_prepared_inline_files.Ready.exclusive binding
            | Some _, None -> false
            | None, _ -> scheduled.schedule.execution_mode = Agent_core.Tool_contract.Serial in
          let scheduled = match ready_files with
            | Some _ when exclusive ->
              {scheduled with schedule = {scheduled.schedule with
                execution_mode = Agent_core.Tool_contract.Serial; batch_size = 1}}
            | Some _ | None -> scheduled in
          if exclusive then Exclusive_gate.acquire_exclusive gate
          else Exclusive_gate.acquire_shared gate;
          let release () =
            if exclusive then Exclusive_gate.release_exclusive gate
            else Exclusive_gate.release_shared gate in
          if halted () then (release (); skip ())
          else (
            let dispatch = match ready_files, binding with
              | Some ready, Some binding -> ready.dispatch binding
              | None, _ | Some _, None -> dispatch in
            let settlement = execute_one ~plan ~run_id ~input
                ~tool_use_id_for_node ~dispatch ?launch_invocation_of ?admit_node
                ?dispatch_compiled ?journal ?observe_node_result scheduled in
            let ticket = Atomic.fetch_and_add tick 1 in
            release ();
            (match settlement.cause with
             | Some _ -> mark_blocked node_id; mark_failed node_id ticket
             | None -> ());
            let _, resolve = find_outcome node_id in
            Eio.Promise.resolve resolve (Wave_settled (settlement, ticket)))))
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
     | (_, cause) :: rest ->
       Error { settled; cause; additional_causes=List.map snd rest;
         effect_disposition = aggregate_effect_disposition settled })
  in
  let batches = schedule_layers ~resource_ordering plan dependency_layers in
  let journal_admission = match journal with
    | None -> Ok ()
    | Some worker -> Keeper_tool_execution_journal.validate_plan worker ~plan
  in
  match journal_admission with
  | Error error -> Error
      { settled = []; cause = Run_journal_rejected error; additional_causes=[]
      ; effect_disposition = Tool_result.Effect_outcome_unknown }
  | Ok () ->
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
         ; additional_causes = []
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
let execute ~plan ~run_id ~dispatch ?launch_invocation_of ?admit_node ?dispatch_compiled ?journal ?observe_node_result () =
  let tool_use_id_for_node ~execution_id _node =
    "composition-node:" ^ Ids.Execution_id.to_string execution_id
  in
  execute_with_tool_use_id
    ~plan
    ~run_id
    ~tool_use_id_for_node
    ~dispatch
    ?launch_invocation_of
    ?admit_node
    ?dispatch_compiled
    ?journal
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
      ?source_context
      ?prepared_files
      ?ready_files
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
      ?admit_node
      ?dispatch_compiled
      ?journal
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
      ; additional_causes = []
      ; cause =
          Outer_completion_mismatch
            { expected = expected_completion; actual = actual_completion }
      ; effect_disposition = Tool_result.Proven_pre_effect
      }
  else
  (* TEL-OK: [handler] below is Keeper_tools_agent_core_handler, which
     already records telemetry (Otel_metric_store.inc_counter). *)
  let dispatch_admitted ?prepared_file ?launch_replay ~tool_use_id ~(node : Keeper_tool_plan.node) ~descriptor ~schedule ~input () =
    (* Replay identity comes from the admitted journal, not the current turn's
       metadata. The owned-job producer receives it as an Existing-only call. *)
    let replay_context =
      match (launch_replay : Keeper_tool_execution_journal.recheck_launch option), journal with
      | None, None | None, Some _ -> Ok None
      | Some _, None -> Error "interrupted launch has no original journal source"
      | Some replay, Some worker ->
          let original = Keeper_tool_execution_journal.worker_source worker in
          let source : Keeper_owned_job_store.source =
            { task_id = original.source_task_id
            ; keeper_turn_id = replay.invocation.keeper_turn_id
            ; turn_ref = Some replay.invocation.turn_ref
            ; trace_id = Some replay.invocation.trace_id
            ; tool_use_id = Some replay.tool_use_id } in
          Keeper_owned_job_invocation.replay_of_source source |> Result.map Option.some in
    let prepared_file = match prepared_files with
      | None -> Ok prepared_file
      | Some prepared ->
        Keeper_prepared_inline_files.for_node ~plan ~node ~input prepared |> Result.map Option.some in
    match prepared_file, replay_context with
    | Error detail, _ ->
        dispatch_result ~failure_effect_disposition:Tool_result.Proven_pre_effect
          (Tool_result.make_err ~tool_name:node.tool_name ~class_:Tool_result.Policy_rejection
             ~effect_disposition:Tool_result.Proven_pre_effect
             ~start_time:(Tool_timing.start ()) detail)
    | Ok _, Error detail ->
        dispatch_result ~failure_effect_disposition:Tool_result.Effect_outcome_unknown
          (Tool_result.make_err ~tool_name:node.tool_name ~class_:Tool_result.Policy_rejection
             ~effect_disposition:Tool_result.Effect_outcome_unknown
             ~start_time:(Tool_timing.start ()) detail)
    | Ok prepared_file, Ok owned_job_replay ->
    let prepared_read, prepared_edit, prepared_write = match prepared_file with
      | None -> None, None, None
      | Some (Keeper_prepared_inline_files.Read read) -> Some read, None, None
      | Some (Keeper_prepared_inline_files.Edit edit) -> None, Some edit, None
      | Some (Keeper_prepared_inline_files.Write write) -> None, None, Some write
    in
    let gate_context = match prepared_file, gate_context with
      | Some _, Some current ->
        let captured = current () in
        Some (fun () -> captured)
      | None, context | Some _, (None as context) -> context
    in
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
        ~source_context:(fun () -> source_context)
        ?owned_job_replay
        ?prepared_read
        ?prepared_edit
        ?prepared_write
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
    let physical_execution_id = Keeper_tool_call_log.invocation_execution_id ~invocation in
    let invocation_started = Tool_timing.start () in
    Cancel_safe.protect
      ~on_exn:(fun exn -> dispatch_result ~physical_execution_id
        ~failure_effect_disposition:Tool_result.Effect_outcome_unknown
        (Tool_result.make_err_of_exn ~class_:Tool_result.Runtime_failure
          ~tool_name:node.tool_name ~start_time:invocation_started exn))
      (fun () ->
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
          ; physical_execution_id = Some physical_execution_id
          ; failure_effect_disposition
          ; deferred_kind
          ; result_bytes = Some result_bytes
          ; truncated_to
          }
        | None ->
          dispatch_result
            ~physical_execution_id
            ~failure_effect_disposition:Tool_result.Effect_outcome_unknown
            ~result_bytes
            ?truncated_to
            result)
  in
  (* Mirror the actual handler's source snapshot priority for the K coordinate,
     then its explicit TurnRef and the job producer's fallback. A mismatched
     trace is unavailable identity, never a license to invent a binding. *)
  let launch_invocation_of () =
    let trace_id = Option.bind source_context (fun context ->
      context.Keeper_tool_call_log_context.trace_id) in
    let original_keeper_turn_id = Option.bind source_context (fun context ->
      context.Keeper_tool_call_log_context.keeper_turn_id) in
    let call_keeper_turn_id = match source_context with
      | Some _ -> original_keeper_turn_id
      | None -> keeper_turn_id () in
    let turn_ref = match call_keeper_turn_id with
      | Some absolute_turn ->
        Some (Ids.Turn_ref.make
          ~trace_id:(Keeper_id.Trace_id.to_string meta.Keeper_meta_contract.runtime.trace_id)
          ~absolute_turn)
      | None -> Option.bind source_context (fun context ->
          match context.Keeper_tool_call_log_context.trace_id,
                context.Keeper_tool_call_log_context.turn with
          | Some trace_id, Some absolute_turn ->
            Some (Ids.Turn_ref.make ~trace_id ~absolute_turn)
          | Some _, None | None, _ -> None) in
    match trace_id, turn_ref with
    | Some trace_id, Some turn_ref
      when String.equal trace_id (Ids.Turn_ref.trace_id turn_ref) ->
      Some { Keeper_tool_execution_journal.trace_id; turn_ref;
             keeper_turn_id = original_keeper_turn_id }
    | Some _, Some _ | Some _, None | None, _ -> None
  in
  let tool_use_id_for_node ~execution_id:_ node =
    nested_tool_use_id ~composition_run_id parent_invocation node.Keeper_tool_plan.id
  in
  let ready_files = Option.map (fun files ->
    { files; dispatch = (fun binding -> dispatch_admitted
        ?prepared_file:(Keeper_prepared_inline_files.Ready.operation binding)) }) ready_files in
  execute_with_tool_use_id
    ~plan
    ~run_id
    ~tool_use_id_for_node
    ~dispatch:(dispatch_admitted ?prepared_file:None)
    ?prepared_files
    ?ready_files
    ~launch_invocation_of
    ?admit_node
    ?dispatch_compiled
    ?journal
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
