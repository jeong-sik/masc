module Catalog = Keeper_tool_composition_catalog
module Executor = Keeper_tool_plan_executor
module Journal = Keeper_tool_execution_journal
module Plan = Keeper_tool_plan
module Activation_ledger = Keeper_skill_activation_ledger
open Keeper_tool_composition_projection
open Result.Syntax
open Keeper_tool_composition_surface_schema
open Keeper_tool_composition_surface_observation
open Keeper_tool_composition_surface_execution
open Keeper_tool_composition_surface_request_control
open Keeper_tool_composition_surface_outcome

let rec async_worker_result
      ~composition_execution
      ~tool_kind
      ?skill_reference
      ?(nested_calls=[])
      ?nested_activation
      ?continuation
      ?(on_recovery_held=(fun ~request_id:_ ~reason:_ -> ()))
      ?after_child_submission
      ?before_child_dispatch
      ?keeper_turn_id
      ?before_plan_execution
      ?after_node_observation
      ?before_child_result_publication
      ?before_child_submission_publication
      ~plan
      ?journal
      ~tool_name
      ~request_id
      ~composition_run_id
      ~source_invocation
      ~request_sw
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~capability_authority
      ~publication_recovery
      ~ctx_snapshot
      ~turn_context
      ?clock
      ()
  =
  Eio_context.with_turn_switch request_sw
  @@ fun () ->
  let meta = match journal with
    | None -> meta
    | Some worker -> (match Journal.worker_source_observation worker with
        | Some {trace_id=Some trace_id;_} ->
            {meta with runtime={meta.Keeper_meta_contract.runtime with trace_id}}
        | Some {trace_id=None;_} | None -> meta) in
  let turn_context = match journal with
    | None -> turn_context
    | Some worker -> original_source_context ~source:(Journal.worker_source worker)
        ~observation:(Journal.worker_source_observation worker) turn_context in
  let observation_context = match journal with
    | None -> turn_context
    | Some worker -> Option.map (fun (context : Keeper_tool_call_log_context.turn_context) ->
        (* Operational fallback coordinates are not original-source evidence.
           Keep execution behavior while withholding uncaptured log identity. *)
        match Journal.worker_source_observation worker with
        | None -> {context with trace_id=None;session_id=None;keeper_turn_id=None;answer_source_ids=[]}
        | Some observation -> {context with trace_id=Option.map Keeper_id.Trace_id.to_string observation.trace_id;
            session_id=observation.session_id;keeper_turn_id=observation.keeper_turn_id}) turn_context in
  let sandbox_factory = Keeper_sandbox_factory.create ~config ~meta () in
  Eio.Switch.on_release request_sw (fun () ->
    Keeper_sandbox_factory.cleanup sandbox_factory);
  let start_time = Tool_timing.start () in
  let run_id = Keeper_tool_plan.Run_id.fresh () in
  let nested_run = Keeper_composition_nested_run.create ~calls:nested_calls ~composition_run_id
      ~delivery_parent_tool_use_id:(Keeper_composition_nested_run.async_result_parent composition_run_id)
      ~parent_invocation:source_invocation ~tool_name
      ~record_activation:(Option.map (fun bound ~invocation ~tool_name ~scope ~reference ->
        Keeper_skill_activation_recorder.record_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference) nested_activation) () in
  Option.iter (fun bound -> Keeper_composition_nested_run.restore_admissions nested_run
    ~find_activation:(fun ~invocation ~tool_name ~scope ~reference ->
      Keeper_skill_activation_recorder.find_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference)) nested_activation;
  let admission = Keeper_composition_nested_run.check_original_admissions nested_run
      ~child_history:(fun ~node_ids -> match journal with
        | Some worker -> Journal.worker_child_admission worker ~node_ids
        | None -> Error Journal.Missing_journal) in
  match admission,continuation with
  | Keeper_composition_nested_run.Original_authority_held rejection,Some continuation when Journal.continuation_dependencies continuation = [] ->
    on_recovery_held ~request_id ~reason:rejection.detail;
    Keeper_msg_async.worker_interrupted ~reason:rejection.detail
  | Keeper_composition_nested_run.Original_authority_held rejection,Some continuation ->
    on_recovery_held ~request_id ~reason:rejection.detail;
    let result = Tool_result.make_deferred ~tool_name ~start_time
        ~data:(`Assoc ["kind",`String "waiting_for_original_child_activation";"cause",rejection.data]) () in
    (match Keeper_msg_async.worker_waiting_for_dependencies
      ~dependencies:(Journal.continuation_dependencies continuation) result with
     | Ok outcome -> outcome
     | Error _ -> Keeper_msg_async.worker_finished (Tool_result.make_err ~tool_name ~start_time
         ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect rejection.detail))
  | Keeper_composition_nested_run.Original_authority_held rejection,None -> Keeper_msg_async.worker_finished (Tool_result.make_err ~tool_name ~start_time
      ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect rejection.detail)
  | Keeper_composition_nested_run.Original_admitted,_ ->
  (* These worker-local joins come only from the protected acceptance factory
     and the canonical reader's typed unavailable branch, never tool text. *)
  let accepted_children = ref [] in
  let unavailable_results = ref [] in
  let dispatch_compiled ~attempt ~target ~tool_use_id:_ ~node ~schedule ~input:_ =
    let start_time = Tool_timing.start () in
    let refuse detail = Executor.dispatch_result
        ~failure_effect_disposition:Tool_result.Proven_pre_effect
        (Tool_result.make_err ~tool_name:node.Plan.tool_name ~start_time
          ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect detail) in
    match target with
    | Plan.Descriptor_target _ | Plan.Child_arguments _ -> refuse "this target does not enter the native child producer"
    | Plan.Child_submission child ->
      Option.iter (fun before -> before ()) before_child_dispatch;
      let original =
        let* context = match nested_activation with
          | Some context -> Ok context
          | None -> Error "native child has no original sealed activation context" in
        let* activation = Keeper_composition_nested_run.admitted_activation nested_run
            ~alias:(Plan.child_alias child.child)
          |> Result.map_error (fun rejection -> rejection.Executor.detail) in
        let* origin,child_plan = Journal.child_origin attempt ~plan ~activation
          |> Result.map_error Journal.error_to_string in
        Ok (context,activation,origin,child_plan) in
      (match original with
       | Error detail -> refuse detail
       | Ok (context,activation,origin,child_plan) ->
         let parent_invocation = Agent_core.Tool_contract.Invocation.create
             ~tool_use_id:activation.skill_tool_use_id ~turn:activation.agent_core_turn
             ~schedule ~completion:Agent_core.Tool_contract.Continue_after_success in
         let physical_execution_id =
           Keeper_tool_call_log.invocation_execution_id ~invocation:parent_invocation in
         let result = named_async_submission_result
             ~skill_reference:(Plan.child_reference child.child) ~plan:child_plan
             ~tool_name:(Plan.child_tool_name child.child)
             ~tool_kind:Keeper_tool_descriptor.Async_composition_tool ~parent_invocation
             ~admission:(Original_child {attempt;parent_plan=plan;origin;context})
             ~on_child_accepted:(fun () -> accepted_children := node.id :: !accepted_children)
             ?before_result_publication:before_child_submission_publication
             ~config ~meta ~capability_authority ~publication_recovery
             ~ctx_snapshot ~turn_context ?clock () in
         Option.iter (fun after -> after result) after_child_submission;
         Executor.dispatch_result ~physical_execution_id result)
    | Plan.Child_result child ->
      (match Journal.child_result_binding attempt ~plan with
       | Error error ->
         unavailable_results := node.id :: !unavailable_results;
         refuse (Journal.error_to_string error)
       | Ok binding ->
         let read = match before_child_result_publication with
           | None -> Keeper_composition_dependency_result.read
           | Some before_manifest_publication ->
             Keeper_composition_dependency_result.For_testing.read
               ~after_owner_read:(fun _ -> ()) ~before_manifest_publication in
         let observed = match read ~config ~meta
             ~args:(`Assoc ["binding",Keeper_composition_dependency.composition_to_json binding]) with
           | Ok observed -> observed
           | Error observed ->
             unavailable_results := node.id :: !unavailable_results;
             observed in
         let data = match observed.data with Some data -> data | None -> `String observed.raw_output in
         let result = match observed.disposition with
           | Tool_result.Deferred () -> Tool_result.make_deferred ~tool_name:node.tool_name ~start_time
               ~data ?metadata:observed.metadata ()
           | Tool_result.Failed class_ -> Tool_result.make_err ~tool_name:node.tool_name ~start_time
               ~class_ ~effect_disposition:observed.failure_effect_disposition
               ~data ?metadata:observed.metadata observed.raw_output
           | Tool_result.Completed () ->
             (match Keeper_composition_child_exports.select
                      ~exports:(Plan.exports (Plan.child_plan child.child)) data with
              | Ok values -> Tool_result.make_ok ~tool_name:node.tool_name ~start_time ~data:(`Assoc values) ()
              | Error error -> Tool_result.make_err ~tool_name:node.tool_name ~start_time
                  ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect
                  (Keeper_composition_child_exports.error_to_string error)) in
         Executor.dispatch_result ~failure_effect_disposition:observed.failure_effect_disposition
           ?deferred_kind:observed.deferred_kind
           (Tool_result.with_retained_artifacts observed.retained_artifacts result)) in
  let on_node_result = Option.map (fun turn_context ->
      observe_node_result
        ?on_receipt_committed:None
        ~composition_tool:tool_name ~composition_execution
        ~composition_tool_kind:tool_kind ~composition_run_id
        ~parent_invocation:source_invocation ~meta ~turn_context) observation_context in
  let on_node_result = match after_node_observation with
    | None -> on_node_result
    | Some after -> Some (fun node ->
        let* () = match on_node_result with None -> Ok () | Some observe -> observe node in
        after node;
        Ok ()) in
  Option.iter (fun before -> before ()) before_plan_execution;
  let execution =
    execute_keeper_plan
    ~capability_authority
    ~plan
    ~run_id
    ?journal
    ~composition_run_id
    ~parent_invocation:
      (async_parent_invocation ~request_id source_invocation)
    ~config
    ~meta
    ~publication_recovery
    ~ctx_snapshot
    ~keeper_turn_id:(match keeper_turn_id with Some callback -> callback
            | None -> keeper_turn_id_of turn_context)
    ~admit_node:(Keeper_composition_nested_run.admit_node nested_run)
    ~dispatch_compiled
    ?source_context:turn_context
    ~turn_sandbox_factory:sandbox_factory
    ?observe_node_result:on_node_result
    ?clock
      ()
  in
  let result =
    result_of_execution
      ~tool_name
      ~tool_kind
      ~start_time
      execution
  in
  let result =
    let nested_scopes = match nested_calls with [] -> None | _::_ ->
      Some (Keeper_composition_nested_run.evidence_to_json nested_run ~plan ~execution) in
    match Keeper_composition_result.project ?nested_scopes ~base_path:config.base_path ~plan ~execution result with
    | Ok result -> result
    | Error { message; _ } ->
      Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure
        ~effect_disposition:Tool_result.Effect_outcome_unknown ~start_time message
  in
  Option.iter
    (fun reference ->
       record_skill_composition_evidence
         ~on_publication_failure:(fun _ -> ())
         ~config
         ~reference
         ~composition_run_id
         ~request_id:(Some request_id)
         ~parent_invocation:source_invocation
         ~meta
         ~composition_tool:tool_name
         ~composition_execution
         ~execution
         ~result)
    skill_reference;
  let waiting_dependencies =
    let collect_waiting_dependencies settled =
      let rec collect reversed = function
        | [] -> Some (List.rev reversed)
        | (node : Executor.node_result) :: rest ->
          (match node.output_validation_error with
           | Some _ -> None
           | None ->
             (match node.result with
              | Tool_result.Completed _ -> collect reversed rest
              | Tool_result.Failed _ -> None
              | Tool_result.Deferred _ ->
                (match node.deferred_kind with
                 | Some (Keeper_tool_execution.Owned_job_result_wait id) ->
                   collect (Keeper_composition_dependency.Owned_job id :: reversed) rest
                 | Some (Keeper_tool_execution.Composition_result_wait binding) ->
                   collect (Keeper_composition_dependency.Composition_result binding :: reversed) rest
                 | None | Some (Keeper_tool_execution.Generic_deferred
                               | External_effect_deferred _) -> None))) in
      collect [] settled
    in
    match journal, execution with
    | None, (Ok _ | Error _) | Some _, Ok _ -> None
    | Some _, Error failure ->
      (match failure.Executor.cause with
       | Executor.Tool_did_not_complete node ->
         (match node.deferred_kind with
          | Some (Keeper_tool_execution.Owned_job_result_wait _ | Composition_result_wait _) ->
            collect_waiting_dependencies failure.settled
          | None | Some (Keeper_tool_execution.Generic_deferred
                        | External_effect_deferred _) -> None)
       | Executor.Run_journal_rejected _ | Plan_execution_failed _
       | Node_observation_failed _ | Outer_completion_mismatch _ -> None)
  in
  let launch_interrupted (node : Executor.node_result) =
    match node.result,Plan.contract plan node.node_id,journal with
    | Tool_result.Failed _,Some {target=Plan.Descriptor_target descriptor;_},Some worker
      when Keeper_tool_descriptor.prepared_leaf_admission descriptor
           = Keeper_tool_descriptor.Owned_job_launch_leaf ->
        (match Journal.launch_recheck worker ~node_id:node.node_id
            ~tool_name:node.tool_name ~input:node.input ~execution_id:node.execution_id ~tool_use_id:node.tool_use_id with
         | Ok (Some _) -> Some (Tool_result.message node.result)
         | Error error -> Some (Journal.error_to_string error)
         | Ok None -> None)
    | (Tool_result.Completed _ | Tool_result.Deferred _ | Tool_result.Failed _),
      (None | Some {target=(Plan.Descriptor_target _ | Plan.Child_arguments _
                          | Plan.Child_submission _ | Plan.Child_result _);_}),
      (None | Some _) -> None in
  let recovery = match execution with
    | Ok _ -> Complete_original_result
    | Error failure ->
      let cause_recovery = function
        | Executor.Tool_did_not_complete node ->
          (match node.execution_origin with
           | Executor.Dispatch_refused -> node_continuation_recovery node
           | Executor.Fresh_dispatch | Executor.Retained_completion ->
              match launch_interrupted node with
              | Some reason -> Hold_original_authority reason
              | None ->
             if List.exists (Plan.Node_id.equal node.node_id) !unavailable_results
                 || List.exists (Plan.Node_id.equal node.node_id) !accepted_children
             then Hold_original_authority (Tool_result.message node.result)
             else match continuation with
               | None -> Complete_original_result
               | Some _ ->
                 match Plan.contract plan node.node_id with
                 | None | Some {target=(Plan.Descriptor_target _ | Plan.Child_arguments _ | Plan.Child_result _);_} ->
                   Complete_original_result
                 | Some {target=Plan.Child_submission _;_} -> node_continuation_recovery node)
        | Executor.Run_journal_rejected error ->
          Hold_original_authority (Journal.error_to_string error)
        | Executor.Node_observation_failed {detail;_} -> Hold_original_authority detail
        | Executor.Plan_execution_failed _ | Executor.Outer_completion_mismatch _ ->
          Complete_original_result in
      List.fold_left (fun recovery cause -> combine_recovery recovery (cause_recovery cause))
        Complete_original_result (Executor.failure_causes failure) in
  match recovery,waiting_dependencies with
  | Hold_original_authority reason,_ ->
    on_recovery_held ~request_id ~reason;
    Keeper_msg_async.worker_interrupted ~reason
  | Complete_original_result,None -> Keeper_msg_async.worker_finished result
  | Complete_original_result,Some dependencies ->
    (match Keeper_msg_async.worker_waiting_for_dependencies ~dependencies result with
     | Ok outcome -> outcome
     | Error _ -> Keeper_msg_async.worker_finished result)

and async_submission_result
      ?skill_reference
      ?nested_calls
      ?nested_activation
      ?draft_reference
      ?run_reference
      ?composition_run_id
      ?journal
      ?continuation
      ?on_recovery_held
      ?refusal
      ?before_submit
      ?observe_submission
      ?on_producer_accepted
      ?observe_settlement
      ~plan
      ~tool_name
      ~tool_kind
      ~parent_invocation
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~capability_authority
      ~publication_recovery
      ~ctx_snapshot
      ~turn_context
      ?clock
      ()
  =
  let turn_context = match journal with
    | None -> turn_context
    | Some journal -> original_source_context ~source:(Journal.source journal)
        ~observation:(Journal.source_observation journal) turn_context in
  let start_time = Tool_timing.start () in
  let composition_run_id = match composition_run_id with
    | Some identity -> identity
    | None -> Keeper_tool_plan.Composition_run_id.fresh () in
  let journal_worker = Atomic.make None in
  let source_task_id = match journal with
    | Some journal -> (Journal.source journal).source_task_id
    | None -> Option.bind turn_context (fun context ->
        context.Keeper_tool_call_log_context.task_id)
  in
  let request_context_fields =
    [ "composition_tool", `String tool_name
    ; "parent_tool_use_id", `String (Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation)
    ; "source_turn", `Int (Agent_core.Tool_contract.Invocation.turn parent_invocation)
    ; ( "composition_run_id"
      , `String
          (Keeper_tool_plan.Composition_run_id.to_string composition_run_id) ) ]
    @ Option.to_list
        (Option.map
           (fun reference -> "skill_reference", Skill_reference.to_yojson reference)
           skill_reference)
    @ Option.to_list (Option.map (fun reference -> "draft_reference", Tool_output.normalized_artifact_ref_to_json reference) draft_reference)
    @ Option.to_list (Option.map (fun reference -> "run_artifact", Tool_output.normalized_artifact_ref_to_json reference) run_reference)
    @ Option.to_list (Option.map (fun task_id -> "source_task_id", `String task_id)
        source_task_id)
  in
  let request_context =
    match request_context_fields with
    | [] -> None
    | fields -> Some fields
  in
  match Keeper_msg_async.server_background_switch () with
  | Error error ->
    let data =
      with_tool_kind_field tool_kind (Keeper_msg_async.submit_error_to_json error)
    in
    result_from_json
      ~tool_name
      ~start_time
      ~class_:Tool_result.Runtime_failure
      ~ok:false
      data
  | Ok background_sw ->
    let submit () = Keeper_msg_async.submit_worker_with_request_id
         ?request_context
         ~on_accepted:(fun request_id ->
           Result.bind
             (Keeper_composition_completion_outbox.prepare ~base_path:config.base_path
                ~keeper_name:meta.name ~request_id ~composition_tool:tool_name
              |> Result.map_error Keeper_composition_completion_outbox.error_to_string)
             (fun () ->
                let* () = match skill_reference,continuation,journal with
                  | None,_,_ -> Ok ()
                  | Some _,Some _,Some journal ->
                    Journal.named_binding journal |> Result.map (fun _ -> ())
                    |> Result.map_error Journal.error_to_string
                  | Some _,(None | Some _),(None | Some _) ->
                    let* binding = Keeper_composition_dependency.composition_of_request_context
                        ~request_id request_context_fields in
                    Keeper_composition_named_run.admit ~base_path:config.base_path
                      ~keeper_name:meta.name binding in
                let* () = match journal with
                | None -> Ok ()
                | Some journal ->
                  let binding = match continuation with
                    | None -> Journal.bind_request journal ~request_id
                    | Some continuation -> Journal.bind_continuation continuation ~request_id in
                  match binding with
                  | Error error -> Error (Journal.error_to_string error)
                  | Ok worker -> Atomic.set journal_worker (Some worker); Ok () in
                Option.fold ~none:(Ok ())
                  ~some:(fun accepted -> accepted request_id) on_producer_accepted))
         ~background_sw
         ~base_path:config.base_path
         ~caller:meta.name
         ~keeper_name:meta.name
         (* Without this the submitter is never told the work finished. The
            tool hands back a request id and returns, so the result reached
            the Keeper only if it remembered to read that id: measured over
            2026-08-18..26, 22 submissions produced 12 reads and a settled
            result waited a median of 21.9s against a median 2.7ms of work.
            The same callback Fusion uses, on the same broker. *)
         ~on_worker_settled:(fun settlement ->
           observe_async_run_settlement
             ~composition_tool:tool_name
             ?skill_reference
             ~composition_tool_kind:tool_kind
             ~composition_run_id
             ~parent_invocation
             ~meta
             ~turn_context
             settlement;
           Keeper_composition_completion_wake.on_worker_settled
             ~base_path:config.base_path
             ~composition_tool:tool_name
             settlement;
           Option.iter (fun observe -> observe settlement) observe_settlement)
         ~f:(fun ~request_id request_sw ->
           match journal, Atomic.get journal_worker with
           | Some _, None ->
             Keeper_msg_async.worker_finished
               (Tool_result.make_err ~tool_name ~start_time:(Tool_timing.start ())
               ~class_:Tool_result.Runtime_failure
               ~effect_disposition:Tool_result.Proven_pre_effect
               "prepared composition worker has no accepted journal binding")
           | (None | Some _), worker ->
           match refusal with
           | Some refusal ->
             let authority =
               let* worker = match worker with
                 | Some worker -> Ok worker | None -> Error "refusal completion requires its canonical journal owner" in
               let* () = Journal.validate_refusal_completion worker ~plan |> Result.map_error Journal.error_to_string in
               let* source = match journal with Some journal -> Ok (Journal.source journal)
                 | None -> Error "refusal completion has no original source" in
               let* () = validate_original_producer_activation ~config source in
               let* bound = Keeper_composition_draft.load_nested_activation ~base_path:config.base_path source
                 |> Result.map_error (fun error -> Yojson.Safe.to_string (Keeper_composition_draft.error_to_json error)) in
               let original = Keeper_composition_nested_run.create
                   ~calls:(match nested_calls with None -> [] | Some calls -> calls)
                   ~composition_run_id ~parent_invocation ~tool_name
                   ~delivery_parent_tool_use_id:(Keeper_composition_nested_run.async_result_parent composition_run_id)
                   ~record_activation:None () in
               Option.iter (fun bound -> Keeper_composition_nested_run.restore_admissions original
                 ~find_activation:(fun ~invocation ~tool_name ~scope ~reference ->
                   Keeper_skill_activation_recorder.find_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference)) bound;
               (match Keeper_composition_nested_run.check_original_admissions original
                   ~child_history:(Journal.worker_child_admission worker) with
                | Keeper_composition_nested_run.Original_admitted -> Ok ()
                | Keeper_composition_nested_run.Original_authority_held rejection ->
                    Error rejection.detail) in
             (match authority with
              | Error reason ->
                Option.iter (fun observe -> observe ~request_id ~reason) on_recovery_held;
                Keeper_msg_async.worker_interrupted ~reason
              | Ok () ->
                let data = continuation_refusal_to_json refusal in
                Keeper_msg_async.worker_finished
                  (Tool_result.make_err ~tool_name ~start_time:(Tool_timing.start ())
                    ~class_:Tool_result.Policy_rejection ~effect_disposition:Tool_result.Proven_pre_effect
                    ~data (Yojson.Safe.to_string data)))
           | None ->
           async_worker_result
             ?on_recovery_held
             ~composition_execution:Catalog.Async
             ~tool_kind
             ?skill_reference
             ?nested_calls
             ?nested_activation
             ?continuation
             ~plan
             ?journal:worker
             ~tool_name
             ~request_id
             ~composition_run_id
             ~source_invocation:parent_invocation
             ~request_sw
             ~config
             ~meta
             ~capability_authority
             ~publication_recovery
             ~ctx_snapshot
             ~turn_context
             ?clock
             ())
         () in
    let submitted =
      match Option.fold ~none:(Ok ()) ~some:(fun before -> before ()) before_submit with
      | Error result -> Error (Submission_result result)
      | Ok () ->
        let outcome = submit () in
        let observed = Option.fold ~none:(Ok ()) ~some:(fun observe -> observe outcome) observe_submission in
        (match observed with
         | Ok () -> Result.map_error (fun error -> Broker_error error) outcome
         | Error detail ->
           let original = match outcome with
             | Ok accepted -> Keeper_msg_async.submit_outcome_to_json accepted
             | Error error -> Keeper_msg_async.submit_error_to_json error in
           Error (Submission_result
             (Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
               ~effect_disposition:Tool_result.Effect_outcome_unknown
               ~data:(`Assoc ["submission_outcome_json",`String (Yojson.Safe.to_string original)])
               ("named submission observation failed: " ^ detail)))) in
    (match submitted with
     | Error (Submission_result result) -> result
     | Error (Broker_error error) ->
       let data =
         with_tool_kind_field
           tool_kind
           (Keeper_msg_async.submit_error_to_json error)
       in
       result_from_json
         ~tool_name
         ~start_time
         ~class_:Tool_result.Runtime_failure
         ~ok:false
         data
     | Ok
         ({ Keeper_msg_async.acceptance = Keeper_msg_async.Durably_accepted
          ; request_id
          } as outcome) ->
       let data =
         `Assoc
           (("composition_tool", `String tool_name)
            :: ( "composition_run_id"
               , `String
                   (Keeper_tool_plan.Composition_run_id.to_string
                      composition_run_id) )
            :: tool_kind_field tool_kind
            :: [ "execution", `String "async"
              ; "request_id", `String request_id
              ; ( "delivery"
                , `Assoc
                    [ "completion_notification", `Bool true
                    ; ( "result_reference"
                      , `Assoc
                          [ "tool", `String Catalog.status_tool_name
                          ; "arguments", `Assoc [ "request_id", `String request_id ]
                          ] )
                    ] )
              ; "submission", Keeper_msg_async.submit_outcome_to_json outcome
              ])
       in
       let binding = match skill_reference,continuation,journal with
         | None,_,_ -> Ok None
         | Some _,Some _,Some journal ->
           Journal.named_binding journal |> Result.map Option.some |> Result.map_error Journal.error_to_string
         | Some _,(None | Some _),(None | Some _) ->
           Keeper_composition_dependency.composition_of_request_context
             ~request_id request_context_fields |> Result.map Option.some in
       (match binding with
        | Ok binding ->
          let data = match data, binding with
            | `Assoc fields, Some binding -> `Assoc (fields @
                ["result_wait", Keeper_composition_dependency.composition_to_json binding])
            | _, None -> data
            | _, Some _ -> data in
          result_from_json ~tool_name ~start_time ~class_:Tool_result.Runtime_failure ~ok:true data
        | Error detail ->
          Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
            ~effect_disposition:Tool_result.Proven_post_effect ~data
            ("async request accepted but its result binding could not be encoded: " ^ detail))
     | Ok
         ({ Keeper_msg_async.acceptance =
              Keeper_msg_async.Reconciliation_required _
          ; _
          } as outcome) ->
       let data =
         `Assoc
           (("composition_tool", `String tool_name)
            :: ( "composition_run_id"
               , `String
                   (Keeper_tool_plan.Composition_run_id.to_string
                      composition_run_id) )
            :: tool_kind_field tool_kind
            :: [ "execution", `String "async"
              ; "submission", Keeper_msg_async.submit_outcome_to_json outcome
              ])
       in
       result_from_json
         ~tool_name
         ~start_time
         ~class_:Tool_result.Runtime_failure
         ~ok:false
         data)

and named_async_submission_result ~skill_reference ~plan ~tool_name ~tool_kind
    ~parent_invocation ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta)
    ~capability_authority ~publication_recovery ~ctx_snapshot ~turn_context
    ~admission ?on_child_accepted ?before_result_publication ?clock () =
  let module Draft = Keeper_composition_draft in
  let module Submission = Keeper_composition_named_submission in
  let start_time = Tool_timing.start () in
  match capability_authority with
  | Keeper_tool_runtime.Compatibility_meta ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Workflow_rejection
      ~effect_disposition:Tool_result.Proven_pre_effect
      "named async execution requires its frozen turn capability surface"
  | Keeper_tool_runtime.Frozen_surface capability_surface ->
    let source_task_id = Option.bind turn_context (fun context ->
      context.Keeper_tool_call_log_context.task_id) in
    let original_activation () = match admission with
        | Original_child {context;_} -> Ok context
        | Fresh_named None -> Error (Submission.Invalid_request "named async submission requires its frozen activation context")
        | Fresh_named (Some context) -> Keeper_skill_activation_recorder.bind_async context
            |> Result.map_error (fun error -> Submission.Invalid_request
              (Keeper_skill_activation_recorder.error_to_string error)) in
    let make_source () =
      let* activation = original_activation () in
      let* () = match admission with
        | Original_child _ -> Ok ()
        | Fresh_named _ ->
      let* recorded = Keeper_skill_activation_recorder.record_bound_composition
          ~config activation ~invocation:parent_invocation ~tool_name skill_reference
        |> Result.map_error (fun error -> Submission.Invalid_request
          (Keeper_skill_activation_recorder.error_to_string error)) in
      (match recorded with
        | Activation_ledger.Recorded _ -> Ok ()
        | Activation_ledger.Already_recorded _ -> Error Submission.Missing_intent) in
      let* recipe = Keeper_tool_plan_request.to_yojson plan
        |> Result.map_error (fun (Keeper_tool_plan_request.Unsubstituted_param {name}) ->
          Submission.Invalid_request ("named async plan retains unbound parameter " ^ name)) in
      let* draft = Draft.prepare ~base_path:config.base_path ~capability_surface
          ~keeper_name:meta.name ~execution:Catalog.Async recipe
        |> Result.map_error (fun error -> Submission.Persistence_failed
          (Yojson.Safe.to_string (Draft.error_to_json error))) in
      let composition_run_id = Keeper_tool_plan.Composition_run_id.fresh () in
      let* run_reference = Draft.record_invocation ~base_path:config.base_path
          ?nested_activation:(match Draft.nested_calls draft with [] -> None | _::_ -> Some activation)
          ~composition_run_id
          ~invocation:parent_invocation draft
        |> Result.map_error (fun error -> Submission.Persistence_failed
          (Yojson.Safe.to_string (Draft.error_to_json error))) in
      let source : Journal.source =
        {keeper_name=meta.name;composition_run_id;draft_reference=Draft.reference draft;run_reference;
         parent_tool_use_id=Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation;
         source_turn=Agent_core.Tool_contract.Invocation.turn parent_invocation;
         source_task_id;
         producer=Journal.Named {tool_name;skill_reference;activation=Some activation;
           origin=(match admission with Fresh_named _ -> Journal.Standalone | Original_child {origin;_} -> origin)}} in
      Journal.prepare ?observation:(source_observation_of_context turn_context)
        ~base_path:config.base_path source
      |> Result.map_error (fun error -> Submission.Journal_rejected error) in
    let prepared =
      let* trace_id,physical_turn_ref,origin = match admission with
        | Fresh_named (Some context) -> Ok (meta.runtime.trace_id,
            Keeper_skill_activation_recorder.physical_turn_ref context,Journal.Standalone)
        | Original_child {context;origin;_} -> Ok (Keeper_skill_activation_recorder.bound_trace_id context,
            Keeper_skill_activation_recorder.bound_turn_ref context,origin)
        | Fresh_named None -> Error (Submission.Invalid_request "original named submission physical frame is unavailable") in
      let* request = Submission.request ~keeper_name:meta.name ~trace_id
          ~physical_turn_ref
          ~invocation:parent_invocation ~source_task_id ~origin ~skill_reference ~tool_name ~plan in
      let* intent = Submission.prepare ~base_path:config.base_path request ~make_source in
      let* child_submission = match admission with
        | Fresh_named _ -> Ok None
        | Original_child {attempt;parent_plan;_} ->
          Journal.record_child_submission attempt ~plan:parent_plan ~child_source:(Submission.source intent)
          |> Result.map Option.some |> Result.map_error (fun error -> Submission.Journal_rejected error) in
      Ok (intent,child_submission) in
    match prepared with
    | Error error -> Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
        ~effect_disposition:Tool_result.Effect_outcome_unknown (Submission.error_to_string error)
    | Ok (intent,child_submission) ->
      let source = Submission.source intent in
      let journal = Submission.journal intent in
      let unresolved error =
        let data = match Submission.unconfirmed_request_id intent with
          | Ok None -> `Assoc []
          | Ok (Some request_id) -> `Assoc ["request_id",`String request_id]
          | Error detail -> `Assoc ["observation_error",`String (Submission.error_to_string detail)] in
        Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
          ~effect_disposition:Tool_result.Effect_outcome_unknown ~data (Submission.error_to_string error) in
      let recover () =
        let* binding = Submission.accepted intent in
        match binding with
        | None -> Ok None
        | Some binding ->
          let* () = match child_submission with
            | None -> Ok ()
            | Some submission ->
              let* accepted = Journal.accepted_child_submission submission
                |> Result.map_error (fun error -> Submission.Journal_rejected error) in
              if Yojson.Safe.equal (Keeper_composition_dependency.composition_to_json accepted)
                  (Keeper_composition_dependency.composition_to_json binding)
              then Ok () else Error Submission.Source_conflict in
          let* owner = Journal.named_result_owner journal binding
            |> Result.map_error (fun error -> Submission.Journal_rejected error) in
          (match child_submission with None -> () | Some _ ->
            Option.iter (fun accepted -> accepted ()) on_child_accepted);
          Ok (Some (Tool_result.make_ok ~tool_name ~start_time
            ~data:(`Assoc (["composition_tool",`String tool_name;
              "execution",`String "async";"request_id",`String binding.request_id;
              "result_wait",Keeper_composition_dependency.composition_to_json binding;
              "current_request",Keeper_msg_async.entry_to_json owner] @ [tool_kind_field tool_kind])) ())) in
      let permit = Atomic.make None in
      let before_submit () =
        match recover () with
        | Error error -> Error (unresolved error)
        | Ok (Some result) -> Error result
        | Ok None ->
          (match Draft.load ~base_path:config.base_path ~capability_surface ~keeper_name:meta.name
              ~sha256:source.draft_reference.sha256 with
           | Error error ->
             let class_ = match admission,error with
               | Fresh_named _,error -> Draft.failure_class error
               | Original_child _,(Draft.Capability_changed | Inputs_rejected _ | Unsupported_node _) ->
                 Tool_result.Policy_rejection
               | Original_child _,(Draft.Storage_failed _ | Draft_read_failed _ | Draft_not_found
                   | Malformed_draft _ | Plan_rejected _ | Nested_rejected _
                   | Different_keeper | Different_package | Publication_rejected _
                   | Skill_not_prepared | Nested_publication_requires_catalog) -> Tool_result.Runtime_failure in
             Error (Tool_result.make_err ~tool_name ~start_time
               ~class_ ~effect_disposition:Tool_result.Proven_pre_effect
               ~data:(Draft.error_to_json error) (Yojson.Safe.to_string (Draft.error_to_json error)))
           | Ok _ ->
             match Submission.begin_submit intent with
             | Ok ticket -> Atomic.set permit (Some ticket); Ok ()
             | Error error ->
               match recover () with
               | Ok (Some result) -> Error result
               | Ok None ->
                 (match error with
                  | Submission.Submission_in_progress ->
                    Log.Keeper.warn
                      "named submission %s: broker-entry phase is durable but admission is absent and its in-memory permit died with the original process; this occurrence stays fail-closed (Submission_in_progress) until the operator resets the intent record (docs/guides/keeper-owned-jobs.md)"
                      (Submission.path intent)
                  | Submission.Invalid_request _ | Submission.Identity_conflict
                  | Submission.Missing_intent | Submission.Unreadable_intent _
                  | Submission.Corrupt_intent _ | Submission.Source_conflict
                  | Submission.Journal_rejected _ | Submission.Stale_permit
                  | Submission.Persistence_failed _ -> ());
                 Error (unresolved error)
               | Error detail -> Error (unresolved detail)) in
      let observe_submission outcome =
        match Atomic.get permit with
        | None -> Error "named submission has no original broker-entry permit"
        | Some permit ->
          (match outcome with
           | Ok outcome -> Submission.observe_submit_outcome permit outcome
           | Error error -> Submission.observe_submit_error permit error)
          |> Result.map_error Submission.error_to_string in
      let result = match recover () with
        | Error error -> unresolved error
        | Ok (Some result) -> result
        | Ok None ->
          async_submission_result ~skill_reference ~journal ~plan
            ?on_producer_accepted:(Option.map (fun submission request_id ->
              Journal.accept_child_submission submission ~request_id
              |> Result.map (fun () -> Option.iter (fun accepted -> accepted ()) on_child_accepted)
              |> Result.map_error Journal.error_to_string) child_submission)
            ~nested_calls:[]
            ?nested_activation:(match source.producer with
              | Journal.Named {activation;_} -> activation | Journal.Prepared -> None)
            ~draft_reference:source.draft_reference ~run_reference:source.run_reference
            ~composition_run_id:source.composition_run_id ~tool_name ~tool_kind ~parent_invocation
            ~before_submit ~observe_submission ~config ~meta ~capability_authority
            ~publication_recovery ~ctx_snapshot ~turn_context ?clock () in
      let result = bind_prepared_result ~composition_run_id:source.composition_run_id
          ~run_reference:source.run_reference ~draft_reference:source.draft_reference result in
      Option.iter (fun before -> before ()) before_result_publication;
      (match Tool_bridge.attach_artifact_manifest
          ~projection:Tool_output.Inline_with_structured_diagnostic ~base_path:config.base_path result with
       | Ok result -> result
       | Error {message;_} ->
         Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
           ~effect_disposition:Tool_result.Effect_outcome_unknown
           ~data:(`Assoc ["submission_result_json",`String (Yojson.Safe.to_string (Tool_result.data result))])
           message)
;;
