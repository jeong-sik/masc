include Keeper_gate_types
include Keeper_gate_authorization
include Keeper_gate_auto_judge_queue
include Keeper_gate_auto_judge_worker
include Keeper_gate_auto_judge_recovery

let defer ?observation request reason =
  match submit ?observation request with
  | Error error -> Unavailable (Queue_storage_unavailable error)
  | Ok submission ->
    let approval_id = submission.approval_id in
    let audit_receipts =
      match submission.disposition with
      | Keeper_approval_queue_result.Pending_created receipt -> [ receipt ]
      | Keeper_approval_queue_result.Pending_deduplicated
      | Keeper_approval_queue_result.Folded_onto_unconsumed_grant -> []
    in
    let reason =
      match reason with
      | Judge_requested ->
        let drained =
          try
            drain_auto_judge_owner
              ~base_path:request.base_path
              ~keeper_name:request.keeper_name
              ()
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
            Error
              ("Auto Judge start failed before worker launch: "
               ^ Printexc.to_string exn)
        in
        (match drained with
         | Error detail -> Auto_judge_unavailable detail
         | Ok (outcome : auto_judge_drain_outcome) ->
           (match List.assoc_opt approval_id outcome.failures with
            | Some detail -> Auto_judge_unavailable detail
            | None -> Judge_requested))
      | Human_requested | Auto_judge_unavailable _ | Mode_state_invalid _ -> reason
    in
    let persist_pre_worker_block ~reason_code detail =
      match
        Keeper_approval_queue.get_pending_entry_for_workspace
          ~base_path:request.base_path
          ~id:approval_id
      with
      | Error error -> Error error
      | Ok None -> Ok ()
      | Ok (Some entry) ->
        (match
           mark_pre_worker_unavailable entry ~reason_code ~operator_detail:detail
         with
         | Ok _ -> Ok ()
         | Error (Keeper_approval_queue_result.Exact_attempt_storage_error error) ->
           Error error
         | Error (Keeper_approval_queue_result.Exact_attempt_rejected rejection) ->
           ignore
             (Keeper_approval.Audit.record
                ~base_path:request.base_path
                ~event_type:
                  Keeper_approval.Audit.Auto_judge_block_observation_superseded
                ~id:approval_id
                ~keeper_name:request.keeper_name
                ~tool_name:request.operation
                ());
           Log.Keeper.warn
             ~keeper_name:request.keeper_name
             "Auto Judge pre-worker block observation superseded approval=%s \
              reason_code=%s reason=%s"
             approval_id
             (Keeper_approval_queue_rules_types
              .summary_attempt_pre_worker_unavailable_code_to_string
                reason_code)
             (Keeper_approval_queue_result.exact_attempt_error_to_string
                (Keeper_approval_queue_result.Exact_attempt_rejected rejection));
           Ok ())
    in
    (match reason with
     | Mode_state_invalid detail ->
       (match
          persist_pre_worker_block
            ~reason_code:
              Keeper_approval_queue_rules_types.Summary_pre_worker_mode_state_invalid
            detail
        with
        | Ok () -> Deferred { operation = request.operation; approval_id; reason; audit_receipts }
        | Error error -> Unavailable (Queue_storage_unavailable error))
     | Auto_judge_unavailable detail ->
       (match
          persist_pre_worker_block
            ~reason_code:
              Keeper_approval_queue_rules_types.Summary_pre_worker_auto_judge_unavailable
            detail
        with
        | Ok () -> Deferred { operation = request.operation; approval_id; reason; audit_receipts }
        | Error error -> Unavailable (Queue_storage_unavailable error))
     | Human_requested | Judge_requested ->
       Deferred { operation = request.operation; approval_id; reason; audit_receipts })
;;

let observe_exact_rule_store_degraded (request : request) error =
  let detail = Keeper_approval_queue_rules_types.rule_store_error_to_string error in
  Log.Keeper.error
    ~keeper_name:request.keeper_name
    "exact Always Allowed rule lookup unavailable operation=%s: %s; continuing configured Gate mode"
    request.operation
    detail;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:[ "keeper", request.keeper_name; "site", "exact_rule_lookup" ]
    ();
  ignore
    (Keeper_approval.Audit.record
       ~base_path:request.base_path
       ~event_type:Keeper_approval.Audit.Gate_exact_rule_store_degraded
       ~id:(Keeper_approval_queue.generate_id ())
       ~keeper_name:request.keeper_name
       ~tool_name:request.operation
       ?turn_id:(request_turn_id request)
       ?task_id:request.task_id
       ())
;;

let observe_exact_rule_expired
      (request : request)
      (rule_match : Keeper_approval_queue_rules_types.rule_match)
  =
  Log.Keeper.warn
    ~keeper_name:request.keeper_name
    "exact Always Allowed rule %s expired operation=%s; continuing configured Gate mode"
    rule_match.rule_id
    request.operation;
  ignore
    (Keeper_approval.Audit.record
       ~base_path:request.base_path
       ~event_type:Keeper_approval.Audit.Gate_exact_rule_expired
       ~id:(Keeper_approval_queue.generate_id ())
       ~keeper_name:request.keeper_name
       ~tool_name:request.operation
       ?turn_id:(request_turn_id request)
       ?task_id:request.task_id
       ~rule_match
       ())
;;

(* Sorted before the judge is paid. What the judge answers is whether an
   effect lands beyond the operator, and a speak lands none: the audio plays
   on the operator's own speakers (or a dashboard device the operator
   connected) and the utterance is appended to the keeper's own chat. The
   text does reach the operator-configured TTS provider first, the way a
   [web_search] query reaches its provider, which the observation table
   already admits without a judge. Derived from the replayable vocabulary so
   a Gate operation added later fails to compile here until someone says
   where its effect lands. Manual mode never asks this: an operator who
   asked to see everything sees speech too. *)
type before_judge =
  | Local_output_only
  | Observation of Keeper_gate_readonly.classification

let classify_before_judge ?shell_ir (request : request) =
  match replayable_operation request.operation with
  | Some Replay_voice_speak -> Local_output_only
  | Some
      ( Replay_write
      | Replay_execute
      | Replay_network_read
      | Replay_connector_post
      | Replay_identity )
  | None ->
    Observation
      (Keeper_gate_readonly.classify_request_with_shell_ir
         ~shell_ir
         ~operation:request.operation
         ~sandbox_profile:request.sandbox_profile
         ~input:request.input)
;;

(* The box is asked after every cheaper authority has declined. A completed
   payload remains its exact restricted result, including nonzero exits.
   Only setup/refusal or unavailable-box evidence retains the Judge; payload
   failure alone never requests effect permission or licenses replay. *)
let decide_after_observation request ~observe =
  match observe with
  | None -> defer request Judge_requested
  | Some run ->
    (match (run () : observation) with
     | Observed_result execution ->
       let source = Observed_in_box execution in
       let audit_receipt =
         audit_allow
           request
           ~decision_source:Keeper_approval_queue_rules_types.Always_allowed
           source
       in
       allow request source [ audit_receipt ]
     | Observed_refused { status; stderr; refusal_kind } ->
       (* Review 5192723206: no refusal the box's own setup channel can
          report justifies allowing without the judge — every refusal is
          the box NOT applying and the program never starting, and the ack
          channel cannot see attempts after "A" anyway (that needs SECCOMP_RET_USER_NOTIF or audit
          logs, a separate observation path). Until that path exists the
          main-line rule holds: every refused observe keeps the judge, and
          the refusal travels to the judge for weighing (RFC-0422 §3.3). *)
       let () =
         Log.Keeper.info
           ~keeper_name:request.keeper_name
           "observe run refused operation=%s %s stderr_bytes=%d \
            refusal_kind=%s; the judge decides"
           request.operation
           (status_label status)
           (String.length stderr)
           (Keeper_approval_queue_rules_types.observed_refusal_kind_to_string
              refusal_kind)
       in
       defer
         ~observation:(observed_refusal ~refusal_kind ~status ~stderr)
         request
         Judge_requested
     | Observed_partly_refused { refusal_kind } ->
       (* One stage's box applied and another stage's box
          could not be built. The row's observation means "nothing started",
          which is false here, so none is written; the judge weighs the
          request itself. *)
       Log.Keeper.info
         ~keeper_name:request.keeper_name
         "observe run partly refused (a stage's box applied) operation=%s refusal_kind=%s; \
          the judge decides"
         request.operation
         (Keeper_approval_queue_rules_types.observed_refusal_kind_to_string refusal_kind);
       defer request Judge_requested
     | Observation_unavailable reason ->
       (* Unlike Observed_refused, no box could be built at all here — a
          missing shim, an unadvertised box, a dispatch the typed gate
          itself refused. That silence says nothing about what the request
          would have reached (a missing box does not distinguish a network
          route from a plain filesystem write inside the keeper's own
          tree), so this keeps the judge exactly as before this stage
          existed. *)
       Log.Keeper.info
         ~keeper_name:request.keeper_name
         "observe run unavailable operation=%s reason=%s; the judge decides"
         request.operation
         reason;
       defer request Judge_requested)
;;

let decide_from_selected_mode ~intent ?shell_ir ?observe request = function
  | Error detail -> defer request (Mode_state_invalid detail)
  | Ok Keeper_gate_mode.Manual -> defer request Human_requested
  | Ok Keeper_gate_mode.Auto_judge when intent = Keeper_tool_execute_typed_input.Request_effect ->
    defer request Judge_requested
  | Ok Keeper_gate_mode.Auto_judge ->
    (* Observation-only requests have a deterministic safety answer —
       read-only argv dispatched into a disposable guest (the typed
       [sandbox_profile] on the request decides that), server-side
       [web_search] reads, and
       [web_fetch] GETs whose destination the fetch checks itself
       (the literal host, and the addresses a DNS name resolves to);
       paying the judge (or the human queue) for them is how a bare `ls`
       became an approval prompt and a keeper stopped searching. Manual
       mode is untouched: an operator who asked to see everything still
       sees everything. A speak is sorted the same way before the judge is
       paid ([classify_before_judge]): its effect lands on the operator's
       own outputs, so it is allowed as [Local_output]. *)
    (match classify_before_judge ?shell_ir request with
     | Local_output_only ->
       let source = Local_output in
       let audit_receipt =
         audit_allow
           request
           ~decision_source:Keeper_approval_queue_rules_types.Always_allowed
           source
       in
       allow request source [ audit_receipt ]
     | Observation Keeper_gate_readonly.Static_observation ->
      let source = Readonly_sandbox in
      let audit_receipt =
        audit_allow
          request
          ~decision_source:Keeper_approval_queue_rules_types.Always_allowed
          source
      in
      allow request source [ audit_receipt ]
     | Observation (Keeper_gate_readonly.Needs_judgment _ as classification) ->
       Log.Keeper.emit
         Log.Info
         ~keeper_name:request.keeper_name
         ~category:Log.Tool
         ~details:
           (`Assoc
              ([ "operation", `String request.operation
               ; "classification", Keeper_gate_readonly.classification_to_yojson classification
               ]
               @ (match request_turn_id request with
                  | Some turn_id -> [ "turn_id", `Int turn_id ]
                  | None -> [])))
         "Command requires judgment before observation";
       defer request Judge_requested
     | Observation (Keeper_gate_readonly.Needs_observation reason as classification) ->
       (match reason with
        | Keeper_gate_readonly.Unproven_request -> ()
        | Keeper_gate_readonly.Git_configuration_override
        | Keeper_gate_readonly.Git_command_requires_execution _ ->
          Log.Keeper.emit
            Log.Info
            ~keeper_name:request.keeper_name
            ~category:Log.Tool
            ~details:
              (`Assoc
                 ([ "operation", `String request.operation
                  ; "classification", Keeper_gate_readonly.classification_to_yojson classification
                  ]
                  @ (match request_turn_id request with
                     | Some turn_id -> [ "turn_id", `Int turn_id ]
                     | None -> [])))
            "Git effects require execution evidence");
       decide_after_observation request ~observe)
  | Ok Keeper_gate_mode.Always_allow ->
    let source = Workspace_always_allow in
    let audit_receipt =
      audit_allow
        request
        ~decision_source:Keeper_approval_queue_rules_types.Always_allowed
        source
    in
    allow request source [ audit_receipt ]
;;

let decide_without_cycle_grant ~intent ~read_mode ?shell_ir ?observe ~keeper_always_allow request =
  if keeper_always_allow
  then (
    let source = Keeper_always_allow in
    let audit_receipt =
      audit_allow
        request
        ~decision_source:Keeper_approval_queue_rules_types.Always_allowed
        source
    in
    allow request source [ audit_receipt ])
  else
    (* Both lanes resolve through the Keeper override (#31128): an operator
       who singled a Keeper out for a higher bar meant it for everything
       that Keeper does, outside services included. *)
    let mode =
      read_mode ~base_path:request.base_path
        ~keeper_name:request.keeper_name
    in
    (match mode with
     | Ok Keeper_gate_mode.Always_allow ->
       let source = Workspace_always_allow in
       let audit_receipt =
         audit_allow
           request
           ~decision_source:Keeper_approval_queue_rules_types.Always_allowed
           source
       in
       allow request source [ audit_receipt ]
     | Error _ | Ok (Keeper_gate_mode.Manual | Keeper_gate_mode.Auto_judge) ->
       (match
          Keeper_approval_queue_rules.find_matching_rule
            ~base_path:request.base_path
            ~keeper_name:request.keeper_name
            ~tool_name:request.operation
            ~input:request.input
            ()
        with
        | Error error ->
          observe_exact_rule_store_degraded request error;
          decide_from_selected_mode ~intent ?shell_ir ?observe request mode
        | Ok (Keeper_approval_queue_rules_types.Rule_match_active rule_match) ->
          let source = Exact_always_rule rule_match.rule_id in
          let audit_receipt =
            audit_allow
              request
              ~rule_match
              ~decision_source:Keeper_approval_queue_rules_types.Always_allowed
              source
          in
          allow request source [ audit_receipt ]
        | Ok (Keeper_approval_queue_rules_types.Rule_match_expired rule_match) ->
          observe_exact_rule_expired request rule_match;
          decide_from_selected_mode ~intent ?shell_ir ?observe request mode
        | Ok Keeper_approval_queue_rules_types.Rule_match_absent ->
          decide_from_selected_mode ~intent ?shell_ir ?observe request mode))
;;

let decide_with_mode ?(intent = Keeper_tool_execute_typed_input.Auto) ~read_mode ?cycle_grant ?shell_ir ?observe ~keeper_always_allow request =
  match canonical_base_path request.base_path with
  | Error reason ->
    Unavailable
      (Queue_storage_unavailable { path = request.base_path; reason })
  | Ok base_path ->
  let request = { request with base_path } in
  let grant_result =
    match cycle_grant with
    | None -> Cycle_grant_not_applicable
    | Some grant -> take_matching_cycle_grant grant request
  in
  match grant_result with
  | Cycle_grant_authorized (approval_id, grant_audit_receipt) ->
    let source = One_shot_resolution approval_id in
    let gate_audit_receipt =
      audit_allow request ~source_approval_id:approval_id source
    in
    allow request source [ grant_audit_receipt; gate_audit_receipt ]
  | Cycle_grant_not_applicable ->
    decide_without_cycle_grant ~intent ~read_mode ?shell_ir ?observe ~keeper_always_allow request
  | Cycle_grant_temporarily_unavailable (approval_id, reason) ->
    Log.Keeper.warn
      ~keeper_name:request.keeper_name
      "one-shot Gate grant unavailable; preserving the unconsumed grant operation=%s reason=%s"
      request.operation
      (unavailable_reason_to_string reason);
    ignore
      (Keeper_approval.Audit.record
         ~base_path:request.base_path
         ~event_type:Keeper_approval.Audit.Gate_grant_unavailable
         ~id:approval_id
         ~keeper_name:request.keeper_name
         ~tool_name:request.operation
         ?turn_id:(request_turn_id request)
         ?task_id:request.task_id
         ~source_approval_id:approval_id
         ());
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:[ "keeper", request.keeper_name; "site", "cycle_grant_lookup" ]
      ();
    Unavailable reason
;;

let decide ?(intent = Keeper_tool_execute_typed_input.Auto) ?cycle_grant ?shell_ir ?observe ~keeper_always_allow request =
  decide_with_mode
    ~read_mode:Keeper_gate_mode.resolve
    ~intent
    ?cycle_grant
    ?shell_ir
    ?observe
    ~keeper_always_allow
    request
;;

let decide_external_service ?cycle_grant ~keeper_always_allow request =
  decide_with_mode
    ~read_mode:Keeper_gate_mode.resolve_external
    ?cycle_grant
    ~keeper_always_allow
    request
;;

module For_testing = struct
  type exact_completion =
    id:string ->
    input_hash:string ->
    sequence:int ->
    slot_id:string ->
    call_id:string ->
    plan_fingerprint:string ->
    request_body_sha256:string ->
    summary:Keeper_approval_queue_rules_types.hitl_context_summary ->
    ( Keeper_approval_queue_result.exact_attempt_transition
    , Keeper_approval_queue_result.exact_attempt_error )
      result

  let auto_judge_entry_ready = auto_judge_entry_ready

  let ready_auto_judges_for_owner ~base_path ~keeper_name entries =
    ready_auto_judges_for_owner ~base_path ~keeper_name entries
  ;;

  let claim_auto_judge = claim_auto_judge
  let release_auto_judge = release_auto_judge
  let active_auto_judges_for_owner = active_auto_judges_for_owner

  type owner_drain_outcome =
    { started_ids : string list
    ; failures : (string * string) list
    ; blocker : auto_judge_drain_blocker option
    }

  let drain_auto_judge_owners_with ~drain_owner owners =
    drain_auto_judge_owners_with
      ~drain_owner:(fun ~base_path ~keeper_name ->
        drain_owner ~base_path ~keeper_name
        |> Result.map (fun (outcome : owner_drain_outcome) ->
          outcome.started_ids, outcome.failures, outcome.blocker))
      owners
  ;;

  type nonrec hitl_worker_spawner = hitl_worker_spawner

  let spawn_auto_judge_entry_with_worker ~spawn_worker entry =
    match spawn_auto_judge_entry_with ~spawn_worker entry with
    | Ok Started -> Ok true
    | Ok Skipped -> Ok false
    | Error reason -> Error reason
  ;;

  let spawn_auto_judge_entry_with_detached_worker ~spawn_worker entry =
    if claim_auto_judge entry
    then
      match
        spawn_claimed_auto_judge_entry_detached_with ~spawn_worker entry
      with
      | Ok Started -> Ok true
      | Ok Skipped -> Ok false
      | Error reason -> Error reason
    else Ok false
  ;;

  let resume_persisted_auto_judges_with_exact_completion =
    resume_persisted_auto_judges_with
  ;;
end
