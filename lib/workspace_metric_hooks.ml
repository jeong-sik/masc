open Masc_domain

let warn_telemetry_drop ~(event : Workspace_telemetry_drop_event.t) exn =
  let exn_str = Printexc.to_string exn in
  let event_family = Workspace_telemetry_drop_event.family_to_wire event in
  let event_kind = Workspace_telemetry_drop_event.kind_to_wire event in
  let details =
    `Assoc
      [ "event_family", `String event_family
      ; "event_kind", `String event_kind
      ; "exception", `String exn_str
      ]
  in
  Telemetry_observe.observe_silent ~kind:"workspace_telemetry_drop_log" (fun () ->
    Log.Workspace.emit
      Log.Warn
      ~details
      (Printf.sprintf
         "telemetry/audit dropped (non-Eio context): %s/%s"
         event_family
         event_kind));
  Telemetry_observe.observe_silent ~kind:"workspace_telemetry_drop_metric" (fun () ->
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_workspace_telemetry_drop
      ~labels:(Workspace_telemetry_drop_event.to_metric_labels event)
      ())
;;

let task_action_of_transition : Masc_domain.task_action -> Audit_log.action = function
  | Masc_domain.Claim -> Audit_log.ClaimTask
  | Masc_domain.Start -> Audit_log.StartTask
  | Masc_domain.Done_action -> Audit_log.DoneTask
  | Masc_domain.Cancel -> Audit_log.CancelTask
  | Masc_domain.Release -> Audit_log.ReleaseTask
  | ( Masc_domain.Submit_for_verification
    | Masc_domain.Approve_verification
    | Masc_domain.Reject_verification ) as action ->
    Audit_log.Custom ("task_" ^ Masc_domain.task_action_to_string action)
;;

let merge_detail_fields fields details =
  match details with
  | `Assoc extra -> `Assoc (fields @ extra)
  | `Null -> `Assoc fields
  | other -> `Assoc (fields @ [ "payload", other ])
;;

let observe_agent_lifecycle
      config
      ~agent_id
      ~(event : Workspace_hooks.agent_lifecycle_event)
      ~details
  =
  let event_kind = Workspace_hooks.agent_lifecycle_event_to_string event in
  let details =
    merge_detail_fields
      [ "event_family", `String "agent_lifecycle"
      ; "event_kind", `String event_kind
      ; "agent_id", `String agent_id
      ]
      details
  in
  let level =
    match event with
    | Session_bound | Session_rebound | Session_ended -> Log.Info
  in
  let message =
    match event with
    | Session_bound -> Printf.sprintf "agent session bound: %s" agent_id
    | Session_rebound -> Printf.sprintf "agent session rebound: %s" agent_id
    | Session_ended -> Printf.sprintf "agent session ended: %s" agent_id
  in
  Log.Workspace.emit level ~details message;
  (match event with
   | Session_ended -> (Atomic.get Workspace_hooks.active_agents_change_fn) `Dec
   | Session_bound | Session_rebound ->
     (Atomic.get Workspace_hooks.active_agents_change_fn) `Inc);
  let audit_details =
    match event with
    | Session_rebound -> merge_detail_fields [ "session_rebound", `Bool true ] details
    | Session_bound | Session_ended -> details
  in
  let action =
    match event with
    | Session_ended -> Audit_log.Custom "agent_session_ended"
    | Session_bound | Session_rebound -> Audit_log.Custom "agent_session_bound"
  in
  try
    Audit_log.log_action
      config
      ~agent_id
      ~action
      ~details:audit_details
      ~outcome:Audit_log.Success
      ();
    if Env_config_core.telemetry_enabled ()
    then (
      match event with
      | Session_ended -> Telemetry_eio.track_agent_unbound config ~agent_id ~reason:"session_ended"
      | Session_bound | Session_rebound ->
        Telemetry_eio.track_agent_session_bound config ~agent_id ())
  with
  | Stdlib.Effect.Unhandled _ as exn ->
    let lifecycle_kind : Workspace_telemetry_drop_event.lifecycle_kind =
      match event with
      | Workspace_hooks.Session_bound -> Session_bound
      | Workspace_hooks.Session_rebound -> Session_rebound
      | Workspace_hooks.Session_ended -> Session_ended
    in
    warn_telemetry_drop ~event:(Agent_lifecycle lifecycle_kind) exn
;;

let observe_task_transition_event
      config
      ~agent_name
      ~task_id
      ~(transition : Masc_domain.task_action)
      ~details
  =
  let transition_s = Masc_domain.task_action_to_string transition in
  let details =
    merge_detail_fields
      [ "event_family", `String "task_transition"
      ; "transition", `String transition_s
      ; "task_id", `String task_id
      ; "agent_id", `String agent_name
      ]
      details
  in
  let level =
    match transition with
    | Masc_domain.Cancel -> Log.Warn
    | Masc_domain.Claim
    | Masc_domain.Start
    | Masc_domain.Done_action
    | Masc_domain.Release
    | Masc_domain.Submit_for_verification
    | Masc_domain.Approve_verification
    | Masc_domain.Reject_verification -> Log.Info
  in
  let message = Printf.sprintf "task %s %s by %s" task_id transition_s agent_name in
  Log.Task.emit level ~details message;
  (try
     Audit_log.log_action
       config
       ~agent_id:agent_name
       ~action:(task_action_of_transition transition)
       ~details
       ~outcome:Audit_log.Success
       ();
     if Env_config_core.telemetry_enabled ()
     then (
       match transition with
       | Masc_domain.Claim | Masc_domain.Start ->
         Telemetry_eio.track_task_started config ~task_id ~agent_id:agent_name
       | Masc_domain.Done_action | Masc_domain.Approve_verification ->
         let duration_ms = Safe_ops.json_int ~default:0 "duration_ms" details in
         Telemetry_eio.track_task_completed config ~task_id ~duration_ms ~success:true;
         Otel_metric_store.record_task_completed ()
       | Masc_domain.Cancel ->
         let duration_ms = Safe_ops.json_int ~default:0 "duration_ms" details in
         Telemetry_eio.track_task_completed config ~task_id ~duration_ms ~success:false;
         Otel_metric_store.record_task_failed ()
       | Masc_domain.Release
       | Masc_domain.Submit_for_verification
       | Masc_domain.Reject_verification -> ())
   with
   | Stdlib.Effect.Unhandled _ as exn ->
     warn_telemetry_drop ~event:(Task_transition transition) exn);
  try
    Keeper_accountability.record_task_transition
      config
      ~agent_name
      ~task_id
      ~transition
      ~details
  with
  | Stdlib.Effect.Unhandled _ as exn ->
    warn_telemetry_drop ~event:(Accountability transition) exn
;;

(* #9795: wire the FSM drift hook to a Otel_metric_store counter emit. *)
let fsm_drift_metric = "masc_task_fsm_drift_total"

let () =
  Otel_metric_store.register_counter
    ~name:fsm_drift_metric
    ~help:
      "Total task FSM drift transitions observed by Workspace_task_lifecycle.decide (e.g. \
       InProgress -> Done skipping the verifier path). Labels: variant (drift variant \
       tag from Workspace_task_lifecycle), force (true | false — was the transition forced \
       past the soft gate). #9795 fleet-wide ratchet-readiness signal."
    ()
;;

let record_fsm_drift ~variant ~force =
  Otel_metric_store.inc_counter
    fsm_drift_metric
    ~labels:[ "variant", variant; ("force", if force then "true" else "false") ]
    ()
;;

(* #9795 follow-up: per-agent breakout so operators can identify
   which keepers most often skip [in_progress] before [done]. *)
let fsm_drift_per_agent_metric = "masc_task_fsm_drift_per_agent_total"

let () =
  Otel_metric_store.register_counter
    ~name:fsm_drift_per_agent_metric
    ~help:
      "Per-agent breakout of task FSM drift transitions (companion to \
       masc_task_fsm_drift_total — purely additive). Lets operators identify which \
       keepers most often skip [in_progress] before [done]. Labels: variant, agent_name, \
       force. Cardinality bounded by fleet size."
    ()
;;

let record_fsm_drift_with_agent ~variant ~force ~agent_name =
  record_fsm_drift ~variant ~force;
  Otel_metric_store.inc_counter
    fsm_drift_per_agent_metric
    ~labels:
      [ "variant", variant
      ; "agent_name", agent_name
      ; ("force", if force then "true" else "false")
      ]
    ()
;;

(* #10449: Task completion path + contract-presence observability. *)
let task_completion_path_metric = "masc_task_completion_path_total"

let () =
  Otel_metric_store.register_counter
    ~name:task_completion_path_metric
    ~help:
      "Total task Done emits classified by completion path and contract presence. Lets \
       operators attribute bypass-rate to creation-side (missing contracts) vs. \
       gate-side (verifier-redirect not firing). Labels: path (claimed_to_done_skip | \
       in_progress_to_done | via_verification | forced_done), contract_state \
       (no_contract | empty_contract | with_contract), agent_name. Cardinality bounded \
       at ~4 x 3 x fleet_size (#10449)."
    ()
;;

let record_task_completion_path ~path ~contract_state ~agent_name =
  Otel_metric_store.inc_counter
    task_completion_path_metric
    ~labels:[ "path", path; "contract_state", contract_state; "agent_name", agent_name ]
    ()
;;

(* #10421: implicit auto-release rate from [task_claim_next]. *)
let task_auto_release_metric = "masc_task_auto_release_total"

let () =
  Otel_metric_store.register_counter
    ~name:task_auto_release_metric
    ~help:
      "Total implicit task auto-releases triggered by [task_claim_next] (mid-work churn \
       or just-claimed churn). Labels: agent_name, from_status (separates [InProgress -> \
       Todo] from [Claimed -> Todo]). Field log motivation: observed 179% release/claim \
       ratio with task hot-potatoed up to 5x in one day (#10421). Cardinality bounded at \
       ~fleet x 2."
    ()
;;

let record_task_auto_release ~agent_name ~from_status =
  Otel_metric_store.inc_counter
    task_auto_release_metric
    ~labels:[ "agent_name", agent_name; "from_status", from_status ]
    ()
;;

let record_workspace_broadcast ~msg_type ~elapsed_s =
  Otel_metric_store.observe_histogram
    Otel_metric_store.metric_workspace_broadcast_duration
    ~labels:[ "msg_type", msg_type ]
    elapsed_s
;;

let record_mention_dedup_decision ~outcome =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_mention_dedup_decisions_total
    ~labels:[ "outcome", outcome ]
    ()
;;

let record_file_lock_attempt ~caller ~retries ~elapsed_s ~outcome =
  if retries > 0
  then
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_file_lock_retries
      ~labels:[ "caller", caller ]
      ~delta:(float_of_int retries)
      ();
  Otel_metric_store.observe_histogram
    Otel_metric_store.metric_file_lock_acquire_seconds
    ~labels:[ "caller", caller; "outcome", outcome ]
    elapsed_s
;;

let record_file_lock_table_cas_retry () =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_file_lock_table_cas_retries
    ()
;;

let process_timeout_metric = Otel_metric_store.metric_process_timeout

let record_process_timeout ~program ~timeout_sec ~origin =
  let stage_label = Timeout_origin.to_label origin in
  Otel_metric_store.inc_counter process_timeout_metric
    ~labels:
      [ "program", program
      ; ("timeout_bucket", Timeout_bucket.(to_label (of_seconds timeout_sec)))
      ; "stage", stage_label
      ]
    ()
;;

let record_discovery_history_failure ~site =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_discovery_history_failures
    ~labels:[ "site", site ]
    ()
;;

let distributed_lock_acquire_failed_metric =
  Otel_metric_store.metric_distributed_lock_acquire_failed
;;

let record_distributed_lock_acquire_failed ~key ~attempts =
  Otel_metric_store.inc_counter
    distributed_lock_acquire_failed_metric
    ~labels:[ "key", key; "attempts", string_of_int attempts ]
    ()
;;

let record_active_agents_change = function
  | `Inc -> Otel_metric_store.inc_gauge Otel_metric_store.metric_active_agents ()
  | `Dec -> Otel_metric_store.dec_gauge Otel_metric_store.metric_active_agents ()
;;

let record_workspace_telemetry_drop event =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_workspace_telemetry_drop
    ~labels:(Workspace_telemetry_drop_event.to_metric_labels event)
    ()
;;

let record_telemetry_observe_failure kind =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_telemetry_observe_failures
    ~labels:[("kind", kind)] ()
;;

let record_anti_rationalization_excuse_pattern ~pattern ~outcome =
  let decision = Task.Anti_rationalization.excuse_pattern_decision_to_string outcome in
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_anti_rationalization_excuse_pattern
    ~labels:[ "pattern", pattern; "decision", decision ]
    ()
;;

let record_anti_rationalization_fallback ~mode ~runtime =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_anti_rationalization_fallback
    ~labels:[ "mode", mode; "runtime", runtime ]
    ()
;;

let install () =
  Atomic.set Workspace_hooks.observe_agent_lifecycle_fn (fun config ~agent_id ~event ~details ->
    observe_agent_lifecycle config ~agent_id ~event ~details);
  Atomic.set Workspace_hooks.observe_task_transition_fn (fun config ~agent_name ~task_id ~transition ~details ->
    (Atomic.get Workspace_hooks.on_task_mutation_fn) ();
    observe_task_transition_event config ~agent_name ~task_id ~transition ~details);

  Atomic.set Workspace_hooks.cleanup_board_artifacts_fn (fun () ->
    let stale_system_daily_sec = 12.0 *. Masc_time_constants.hour in
    let board_artifact_title title =
      let title = String.lowercase_ascii (String.trim title) in
      String.starts_with ~prefix:"[keeper daily]" title
    in
    let board_artifact_author author =
      let author = String.lowercase_ascii (String.trim author) in
      author = "auto-researcher"
      || String.starts_with ~prefix:"qa-" author
      || ((not (String.contains author ' ')) && String.ends_with ~suffix:"-probe" author)
    in
    let now = Time_compat.now () in
    Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~limit:5200 ()
    |> List.fold_left
         (fun removed (post : Board.post) ->
            let author = Board.Agent_id.to_string post.author in
            if
              board_artifact_author author
              || (String.equal (String.lowercase_ascii author) "keeper"
                  && board_artifact_title post.title
                  && now -. post.updated_at >= stale_system_daily_sec)
            then (
              match
                Board_dispatch.delete_post ~post_id:(Board.Post_id.to_string post.id)
              with
              | Ok () -> removed + 1
              | Error _ -> removed)
            else removed)
         0);

  Atomic.set Workspace_hooks.activity_emit_fn (fun config ~actor ?subject ~kind ~payload ~tags () ->
    try
      ignore
        (Activity_graph.emit
           config
           ~actor:(Activity_graph.entity ~kind:actor.Workspace_hooks.kind actor.id)
           ?subject:
             (Option.map
                (fun (s : Workspace_hooks.activity_entity) ->
                   Activity_graph.entity ~kind:s.kind s.id)
                subject)
           ~kind
           ~payload
           ~tags
           ())
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Log.Workspace.warn "activity_graph emit failed: %s" (Printexc.to_string exn));

  Atomic.set Workspace_hooks.agent_economy_earn_fn (fun ~base_path ~agent_name ~reason ->
    match Economy.earn ~base_path ~agent_name ~kind:Earn_task_done ~reason () with
    | Ok _bal -> ()
    | Error msg -> Log.Misc.error "task earn failed: %s" msg);

  Atomic.set Workspace_hooks.relation_on_leave_fn Relation_materializer.on_agent_session_ended;
  Atomic.set Workspace_hooks.relation_on_task_done_fn Relation_materializer.on_task_done;

  Atomic.set Workspace_hooks.subscribe_messages_fn (fun ~subscriber ->
    let _ =
      Subscriptions.SubscriptionStore.subscribe
        ~subscriber
        ~resource:Subscriptions.Messages
        ()
    in
    ());

  Atomic.set Workspace_hooks.tool_assigned_fn Tool_assignment_telemetry.emit_assigned;

  Atomic.set Workspace_hooks.fsm_drift_observer_fn record_fsm_drift_with_agent;
  Atomic.set Workspace_hooks.task_completion_path_observed_fn record_task_completion_path;
  Atomic.set Workspace_hooks.task_auto_release_observed_fn record_task_auto_release;
  Atomic.set Workspace_hooks.workspace_broadcast_observed_fn record_workspace_broadcast;
  Atomic.set Workspace_hooks.mention_dedup_decision_fn record_mention_dedup_decision;
  Atomic.set File_lock_eio.on_lock_attempt_fn record_file_lock_attempt;
  Atomic.set File_lock_eio.on_cas_retry_fn record_file_lock_table_cas_retry;
  Atomic.set Process_eio.process_timeout_observer_fn record_process_timeout;
  Atomic.set Discovery_history.failure_observer_fn record_discovery_history_failure;
  Atomic.set Workspace_hooks.distributed_lock_acquire_failed_fn record_distributed_lock_acquire_failed;
  Atomic.set Workspace_hooks.active_agents_change_fn record_active_agents_change;
  Atomic.set Workspace_hooks.workspace_telemetry_drop_fn record_workspace_telemetry_drop;
  Atomic.set Workspace_hooks.telemetry_observe_failure_fn record_telemetry_observe_failure;

  Atomic.set Task.Anti_rationalization.excuse_pattern_observer_fn record_anti_rationalization_excuse_pattern;
  Atomic.set Task.Anti_rationalization.fallback_observer_fn record_anti_rationalization_fallback;

  Atomic.set Task.Anti_rationalization.run_llm_reviewer_fn (fun ?sw ~evaluator_runtime ~prompt ~report_tool_schema () ->
    let verdict_ref = ref None in
    let dispatch ~name ~args =
      let start_time = Time_compat.now () in
      match Task.Anti_rationalization.parse_review_verdict_from_json args with
      | Ok v ->
        verdict_ref := Some v;
        Tool_result.error
          ~tool_name:name
          ~start_time
          (match v with
           | Approve -> "Approved"
           | Reject r -> "Rejected: " ^ r)
      | Error msg ->
        Log.Task.warn
          "[anti-rationalization] structured verdict parse failed: %s"
          msg;
        Tool_result.error
          ~tool_name:name
          ~start_time
          (Printf.sprintf "Invalid verdict format: %s" msg)
    in
    match
	      Masc_oas_bridge.run_with_caller
	        ~caller:Env_config_oas_bridge.Anti_rationalization
	        (fun () ->
	           let base_path = Env_config_core.base_path () in
	           Keeper_turn_driver_wrappers.run_named_with_masc_tools
	             ~runtime_id:evaluator_runtime
	             ~base_path
	             ~goal:prompt
             ~masc_tools:[ report_tool_schema ]
             ~dispatch
             
             ~temperature:Runtime_provider_defaults.deterministic_temperature
             ~max_tokens:200
             ~approval:Approval_callbacks.auto_approve
             ?sw
             ())
    with
    | Ok result ->
      let text = Agent_sdk_response.text_of_response result.response in
      Ok (!verdict_ref, text)
    | Error err ->
      Error err);

  Atomic.set Workspace_hooks.record_task_metric_fn (fun config ~agent_id ~task_id ~started_at ~completed_at ~success ~error_message ~collaborators ~handoff_from ~handoff_to ->
    let metric : Metrics_store_eio.task_metric = {
      id = Printf.sprintf "metric-%s-%d" task_id (Stdlib.Int.of_float (Time_compat.now () *. 1000.));
      agent_id;
      task_id;
      started_at;
      completed_at;
      success;
      error_message;
      collaborators;
      handoff_from;
      handoff_to;
    } in
    try let _ = Metrics_store_eio.record config metric in ()
    with Eio.Cancel.Cancelled _ as e -> raise e
       | exn -> Log.Task.error ~keeper_name:task_id "Metrics_store_eio.record dynamic hook failed: %s" (Stdlib.Printexc.to_string exn));

  Atomic.set Task.Anti_rationalization.is_runtime_permanently_dead_fn (fun err ->
    match Keeper_turn_driver.classify_masc_internal_error err with
    | _ -> false);

  Atomic.set Workspace_hooks.record_thompson_result_fn (fun ~agent_name ~success ~reason ->
    let direction = if success then `Up else `Down in
    let verdict =
      if success then Thompson_sampling.Pass
      else
        let r = Option.value ~default:"task_cancelled" reason in
        Thompson_sampling.Fail r
    in
    Thompson_sampling.record_vote ~agent_name ~direction;
    Thompson_sampling.record_quality_signal ~agent_name ~verdict);

  Atomic.set Workspace_hooks.push_task_event_fn (fun ~event_type ~details ->
    let payload = `Assoc (
      ("type", `String event_type) ::
      ("timestamp", `Float (Time_compat.now ())) ::
      details
    ) in
    Subscriptions.push_event_to_sessions payload);

  Atomic.set Workspace_hooks.verification_submit_request_fn
    (fun config ~task ~assignee ~verification_id ~evidence_refs ->
       Verification_protocol.create_submit_request
         ~config
         ~task
         ~assignee
         ~verification_id
         ~evidence_refs);

  Atomic.set Workspace_hooks.verification_delete_request_fn
    (fun config ~verification_id ->
       Verification_protocol.delete_verification_request ~config ~verification_id);

  Atomic.set Workspace_hooks.verification_record_verdict_fn
    (fun config ~task_id ~verifier ~verification_id ~decision ->
       match decision with
       | `Approve notes ->
         Verification_protocol.record_approve_verification
           ~config
           ~task_id
           ~verifier
           ~verification_id
           ~notes
       | `Reject reason ->
         Verification_protocol.record_reject_verification
           ~config
           ~task_id
           ~verifier
           ~verification_id
           ~reason);

  Atomic.set Workspace_hooks.verification_notify_submit_fn
    (fun config ~task ~assignee ~verification_id ~evidence_refs ->
       Verification_protocol.notify_submit_for_verification
         ~config
         ~task
         ~assignee
         ~verification_id
         ~evidence_refs);

  Atomic.set Workspace_hooks.verification_notify_verdict_fn
    (fun ~task_id ~verifier ~verification_id ~decision ->
       match decision with
       | `Approve notes ->
         Verification_protocol.notify_approve_verification
           ~task_id
           ~verifier
           ~verification_id
           ~notes
       | `Reject reason ->
         Verification_protocol.notify_reject_verification
           ~task_id
           ~verifier
           ~verification_id
           ~reason);

  Atomic.set Workspace_hooks.is_admin_agent_fn (fun ~base_path ~agent_name ->
    match Auth.read_initial_admin base_path with
    | Some admin when String.equal agent_name admin -> true
    | _ -> false);

  (* Wrapper for cache desync cleared *)
  let original_cache_desync = Atomic.get Workspace_hooks.cache_desync_cleared_fn in
  Atomic.set Workspace_hooks.cache_desync_cleared_fn (fun config ~module_name ~task_id ~status ->
    original_cache_desync config ~module_name ~task_id ~status;
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_cache_desync_cleared
      ~labels:[ "module", module_name; "status", status ]
      ());

  let decide_hook
        ~(task_id : string)
        ~(task_opt : Masc_domain.task option)
        ~(notes : string)
        ~(handoff : Masc_domain.task_handoff_context option)
        ()
      : Workspace_hooks.evidence_gate_verdict
    =
    match Cdal_evidence_gate.decide ~task_id ~task_opt ~notes ~handoff_context:handoff () with
    | Cdal_evidence_gate.Pass -> Workspace_hooks.Pass
    | Cdal_evidence_gate.Reject { reason; rule_id; hint; payload_json } ->
      Workspace_hooks.Reject { reason; rule_id; hint; payload_json }
  in
  Atomic.set Workspace_hooks.cdal_evidence_gate_decide_fn decide_hook;
  ()
;;
