open Alcotest
open Masc

module Q = Keeper_event_queue

let stimulus ~post_id ~urgency ~arrived_at ~payload : Q.stimulus =
  { post_id; urgency; arrived_at; payload }
;;

let queue_of stimuli =
  List.fold_left Q.enqueue Q.empty stimuli
;;

let test_post_tool_boundary_targets_manual_compaction () =
  let source =
    stimulus
      ~post_id:"source"
      ~urgency:Q.Normal
      ~arrived_at:900.
      ~payload:Q.Bootstrap
  in
  let manual =
    stimulus
      ~post_id:Q.manual_compaction_post_id
      ~urgency:Q.Immediate
      ~arrived_at:990.
      ~payload:Q.Manual_compaction_requested
  in
  let pending = queue_of [ source; manual ] in
  let request =
    Keeper_unified_turn.manual_compaction_preemption_request
      ~wake:(Keeper_registry.Woken [ Q.Bootstrap ])
      ~now:1000.
      pending
  in
  match request with
  | Some
      { Keeper_agent_run.reason =
          Keeper_agent_run.Durable_stimulus_waiting summary
      } ->
    check int "both durable stimuli remain visible" 2 summary.pending_count;
    (match summary.head with
     | Some selected ->
       check string
         "yield names the runtime source that runs next"
         Q.manual_compaction_post_id
         selected.post_id
     | None -> fail "manual compaction yield lost its selected source");
    check (float 0.001) "selected-source age is exact" 10. summary.head_age_sec
  | Some { reason = Keeper_agent_run.Operation_queued } ->
    fail "manual compaction preemption was mislabeled as chat"
  | None ->
    fail "pending manual compaction did not preempt the in-flight source"
;;

let test_manual_compaction_never_preempts_itself () =
  let manual =
    stimulus
      ~post_id:Q.manual_compaction_post_id
      ~urgency:Q.Immediate
      ~arrived_at:990.
      ~payload:Q.Manual_compaction_requested
  in
  check bool
    "current manual compaction source continues"
    true
    (Option.is_none
       (Keeper_unified_turn.manual_compaction_preemption_request
          ~wake:(Keeper_registry.Woken [ Q.Manual_compaction_requested ])
          ~now:1000.
          (queue_of [ manual ])))
;;

let test_proactive_turn_uses_existing_general_queue_yield () =
  let manual =
    stimulus
      ~post_id:Q.manual_compaction_post_id
      ~urgency:Q.Immediate
      ~arrived_at:990.
      ~payload:Q.Manual_compaction_requested
  in
  check bool
    "manual source preemption is scoped to an in-flight durable source"
    true
    (Option.is_none
       (Keeper_unified_turn.manual_compaction_preemption_request
          ~wake:Keeper_registry.Proactive_tick
          ~now:1000.
          (queue_of [ manual ])))
;;

let test_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String name
         ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
         ; "trace_id", `String ("trace-" ^ name)
         ])
  with
  | Ok meta -> meta
  | Error detail -> failf "meta fixture failed: %s" detail
;;

let enqueue_exn ~base_path keeper_name source =
  match
    Keeper_registry_event_queue.enqueue_durable_result
      ~base_path
      keeper_name
      source
  with
  | Ok () -> ()
  | Error detail -> failf "durable enqueue failed: %s" detail
;;

let test_owner_intake_compacts_then_resumes_source () =
  Eio_main.run
  @@ fun env ->
  Masc_test_deps.ensure_rng_initialized ();
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run
  @@ fun sw ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  let keeper_name = "manual-compaction-preemption" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.unregister ~base_path keeper_name;
      Masc_test_deps.cleanup_test_workspace base_path)
  @@ fun () ->
  let config = Workspace.default_config base_path in
  let meta = test_meta keeper_name in
  ignore
    (Keeper_registry.For_testing.register
       ~base_path
       keeper_name
       meta);
  let ctx : _ Keeper_types_profile.context =
    { config
    ; agent_name = "manual-compaction-preemption-test"
    ; sw
    ; clock = Eio.Stdenv.clock env
    ; proc_mgr = None
    ; net = None
    ; publication_recovery_provider =
        Masc_test_deps.non_runtime_publication_recovery_provider
    }
  in
  let source =
    stimulus
      ~post_id:"durable-source"
      ~urgency:Q.Normal
      ~arrived_at:1.
      ~payload:Q.Bootstrap
  in
  let manual =
    stimulus
      ~post_id:Q.manual_compaction_post_id
      ~urgency:Q.Immediate
      ~arrived_at:2.
      ~payload:Q.Manual_compaction_requested
  in
  enqueue_exn ~base_path keeper_name source;
  enqueue_exn ~base_path keeper_name manual;
  let first =
    Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx
      ~meta_after_triage:meta
      ~pending_board_events:[]
  in
  let selected_manual =
    match first.pending_selection with
    | Some selected ->
      check string
        "manual compaction is selected ahead of the source"
        Q.manual_compaction_post_id
        selected.source.post_id;
      selected
    | None -> fail "manual compaction preemption selected no source"
  in
  (match
     Keeper_registry_event_queue.ack_pending_result
       ~base_path
       keeper_name
       ~selection:selected_manual
   with
   | Ok () -> ()
   | Error detail -> failf "manual compaction ACK failed: %s" detail);
  let after_compaction =
    match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
    | Ok queue -> queue
    | Error detail -> failf "queue reload failed: %s" detail
  in
  check int "only the original source remains" 1 (Q.length after_compaction);
  let resumed =
    Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx
      ~meta_after_triage:meta
      ~pending_board_events:[]
  in
  match resumed.pending_selection with
  | Some selected ->
    check string
      "the exact original source resumes after compaction"
      source.post_id
      selected.source.post_id
  | None -> fail "the original source disappeared after manual compaction"
;;

let () =
  run
    "keeper manual compaction preemption"
    [ ( "post-tool boundary"
      , [ test_case
            "targets queued manual compaction"
            `Quick
            test_post_tool_boundary_targets_manual_compaction
        ; test_case
            "manual compaction does not preempt itself"
            `Quick
            test_manual_compaction_never_preempts_itself
        ; test_case
            "proactive turns stay on the general queue-yield path"
            `Quick
            test_proactive_turn_uses_existing_general_queue_yield
        ] )
    ; ( "owner intake"
      , [ test_case
            "compacts first and resumes the exact source"
            `Quick
            test_owner_intake_compacts_then_resumes_source
        ] )
    ]
;;
