module AQ = Masc.Keeper_approval_queue
module Gate = Masc.Keeper_gate
module Registry_queue = Masc.Keeper_registry_event_queue
module Queue_state = Keeper_event_queue_state

let yojson = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_approval_queue_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec remove path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  try remove dir with
  | Sys_error _ -> ()
;;

let rec ensure_dir path =
  if Sys.file_exists path
  then ()
  else (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let durable_resolution_opt ~base_path ~keeper_name ~approval_id =
  Registry_queue.snapshot ~base_path keeper_name
  |> Keeper_event_queue.to_list
  |> List.find_map (fun (stimulus : Keeper_event_queue.stimulus) ->
    match stimulus.payload with
    | Keeper_event_queue.Hitl_resolved resolution
      when String.equal resolution.approval_id approval_id ->
      Some resolution
    | _ -> None)
;;

let require_some message = function
  | Some value -> value
  | None -> Alcotest.fail message
;;

let drop_resolution ~base_path ~keeper_name resolution =
  let post_id = Keeper_event_queue.hitl_resolution_post_id resolution in
  match Registry_queue.drop_by_post_id ~base_path keeper_name ~post_id with
  | Ok _ -> ()
  | Error reason -> Alcotest.fail reason
;;

let lease_for_resolution (resolution : Keeper_event_queue.hitl_resolution) =
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = Keeper_event_queue.hitl_resolution_post_id resolution
    ; urgency = Keeper_event_queue.Immediate
    ; arrived_at = 1.0
    ; payload = Keeper_event_queue.Hitl_resolved resolution
    }
  in
  let pending = Keeper_event_queue.enqueue Keeper_event_queue.empty stimulus in
  let state = Queue_state.with_pending pending Queue_state.empty in
  match Queue_state.claim_when ~claimed_at:2.0 ~ready:(fun _ -> true) state with
  | Ok (_, Some lease) -> lease
  | Ok (_, None) -> Alcotest.fail "approved resolution was not claimed"
  | Error reason -> Alcotest.fail reason
;;

let submit_with_context
      ?turn_id
      ?request_context
      ?task_id
      ?continuation_channel
      ~base_path
      ~keeper_name
      ~input
      ()
  =
  match
    AQ.submit_pending
      ~keeper_name
      ~tool_name:"external-effect"
      ~input
      ~base_path
      ?turn_id
      ?request_context
      ?task_id
      ?continuation_channel
      ()
  with
  | Ok id -> id
  | Error error -> Alcotest.fail (AQ.storage_error_to_string error)
;;

let submit ~base_path ~keeper_name ~input =
  submit_with_context ~base_path ~keeper_name ~input ()
;;

let reject_and_cleanup id =
  match AQ.resolve ~id ~decision:(AQ.Decision.Reject "test cleanup") with
  | Ok () -> ()
  | Error error -> Alcotest.fail (AQ.resolve_error_to_string error)
;;

let test_pending_store_lock_serializes_eio_fibers () =
  Eio_main.run @@ fun _environment ->
  let first_entered, signal_first_entered = Eio.Promise.create () in
  let second_attempted, signal_second_attempted = Eio.Promise.create () in
  let release_first, signal_release_first = Eio.Promise.create () in
  let order = ref [] in
  Eio.Fiber.all
    [ (fun () ->
        AQ.For_testing.with_pending_store_lock (fun () ->
          order := "first_entered" :: !order;
          Eio.Promise.resolve signal_first_entered ();
          Eio.Promise.await release_first;
          order := "first_released" :: !order))
    ; (fun () ->
        Eio.Promise.await first_entered;
        Eio.Promise.resolve signal_second_attempted ();
        AQ.For_testing.with_pending_store_lock (fun () ->
          order := "second_entered" :: !order))
    ; (fun () ->
        Eio.Promise.await second_attempted;
        Eio.Promise.resolve signal_release_first ())
    ];
  Alcotest.(check (list string))
    "second fiber enters only after the yielding durable transition releases"
    [ "first_entered"; "first_released"; "second_entered" ]
    (List.rev !order)
;;

let test_dedup_never_merges_distinct_origins () =
  let base_path = temp_dir () in
  let keeper_name = "queue-distinct-origin" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input = `Assoc [ "target", `String "same-action" ] in
       let dashboard_a =
         Keeper_continuation_channel.Dashboard { thread_id = "thread-a" }
       in
       let dashboard_b =
         Keeper_continuation_channel.Dashboard { thread_id = "thread-b" }
       in
       let first =
         submit_with_context
           ~turn_id:1
           ~continuation_channel:dashboard_a
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       let same =
         submit_with_context
           ~turn_id:1
           ~continuation_channel:dashboard_a
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       Alcotest.(check string) "same origin deduplicates" first same;
       let another_turn =
         submit_with_context
           ~turn_id:2
           ~continuation_channel:dashboard_a
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       let another_channel =
         submit_with_context
           ~turn_id:1
           ~continuation_channel:dashboard_b
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       List.iter
         (fun id ->
            Alcotest.(check bool) "distinct origin has its own request" true
              (not (String.equal first id)))
         [ another_turn; another_channel ];
       List.iter reject_and_cleanup
         [ first; another_turn; another_channel ])
;;

let check_update label expected = function
  | Ok actual -> Alcotest.(check bool) label expected actual
  | Error error -> Alcotest.fail (AQ.storage_error_to_string error)
;;

let read_pending_snapshot ~base_path =
  Yojson.Safe.from_file (AQ.For_testing.pending_store_path ~base_path)
;;

let write_pending_snapshot ~base_path json =
  let path = AQ.For_testing.pending_store_path ~base_path in
  ensure_dir (Filename.dirname path);
  Out_channel.with_open_text path (fun channel ->
    output_string channel (Yojson.Safe.pretty_to_string json))
;;

let install_exn ~base_path =
  match AQ.install_persistence ~base_path with
  | Ok report -> report
  | Error error -> Alcotest.fail (AQ.install_error_to_string error)
;;

let test_install_serializes_snapshot_read_with_same_base_mutation () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       write_pending_snapshot
         ~base_path
         (`Assoc
            [ "version", `Int 2
            ; "pending", `List []
            ; "deliveries", `List []
            ]);
       Eio_main.run @@ fun _environment ->
       let snapshot_loaded, signal_snapshot_loaded = Eio.Promise.create () in
       let mutation_attempted, signal_mutation_attempted = Eio.Promise.create () in
       let release_install, signal_release_install = Eio.Promise.create () in
       let install_done, signal_install_done = Eio.Promise.create () in
       let mutation_done, signal_mutation_done = Eio.Promise.create () in
       let mutation_completed_before_release = ref false in
       Eio.Fiber.all
         [ (fun () ->
             let result =
               AQ.For_testing.install_persistence_with_after_load_hook
                 ~base_path
                 ~after_load:(fun () ->
                   Eio.Promise.resolve signal_snapshot_loaded ();
                   Eio.Promise.await release_install)
             in
             Eio.Promise.resolve signal_install_done result)
         ; (fun () ->
             Eio.Promise.await snapshot_loaded;
             Eio.Promise.resolve signal_mutation_attempted ();
             let id =
               submit
                 ~base_path
                 ~keeper_name:"queue-install-race"
                 ~input:(`Assoc [ "target", `String "after-load" ])
             in
             Eio.Promise.resolve signal_mutation_done id)
         ; (fun () ->
             Eio.Promise.await mutation_attempted;
             mutation_completed_before_release :=
               Option.is_some (Eio.Promise.peek mutation_done);
             Eio.Promise.resolve signal_release_install ())
         ];
       Alcotest.(check bool)
         "same-base mutation waits for snapshot installation"
         false
         !mutation_completed_before_release;
       let report = Eio.Promise.await install_done in
       let mutation_id = Eio.Promise.await mutation_done in
       (match report with
        | Error error -> Alcotest.fail (AQ.install_error_to_string error)
        | Ok report -> Alcotest.(check int) "empty snapshot installed" 0 report.loaded_pending);
       Alcotest.(check int) "mutation remains in memory" 1 (AQ.pending_count ());
       Alcotest.(check bool)
         "mutation id remains addressable"
         true
         (Option.is_some (AQ.get_pending_entry ~id:mutation_id));
       let open Yojson.Safe.Util in
       let persisted_ids =
         read_pending_snapshot ~base_path
         |> member "pending"
         |> to_list
         |> List.map (fun entry -> entry |> member "id" |> to_string)
       in
       Alcotest.(check bool)
         "mutation remains in the durable snapshot"
         true
         (List.mem mutation_id persisted_ids))
;;

let test_submit_is_nonblocking_and_exactly_deduplicated () =
  let base_path = temp_dir () in
  let keeper_name = "queue-exact-submit" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input =
         `Assoc
           [ "target", `String "document"
           ; "payload", `Assoc [ "text", `String "hello"; "nonce", `Int 1 ]
           ]
       in
       let request_context =
         `Assoc [ "user_message", `String "write the exact document" ]
       in
       let first =
         submit_with_context
           ~turn_id:12
           ~request_context
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       let reordered =
         `Assoc
           [ "payload", `Assoc [ "nonce", `Int 1; "text", `String "hello" ]
           ; "target", `String "document"
           ]
       in
       let same =
         submit_with_context
           ~turn_id:12
           ~request_context
           ~base_path
           ~keeper_name
           ~input:reordered
           ()
       in
       Alcotest.(check string) "same exact request" first same;
       let changed =
         submit
           ~base_path
           ~keeper_name
           ~input:
             (`Assoc
                [ "target", `String "document"
                ; "payload", `Assoc [ "text", `String "hello"; "nonce", `Int 2 ]
                ])
       in
       Alcotest.(check bool) "changed field is a different request" true
         (not (String.equal first changed));
       (match AQ.get_pending_entry ~id:first with
        | None -> Alcotest.fail "pending request missing"
        | Some entry ->
          Alcotest.(check bool) "summary is not started by queue" true
            (entry.summary_status = AQ.Summary_not_requested);
          Alcotest.check (Alcotest.option yojson)
            "exact outer-turn context"
            (Some request_context)
            entry.request_context);
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       (match AQ.get_pending_entry ~id:first with
        | Some entry ->
          Alcotest.check (Alcotest.option yojson)
            "outer-turn context survives restart"
            (Some request_context)
            entry.request_context
        | None -> Alcotest.fail "pending request was not restored");
       reject_and_cleanup first;
       reject_and_cleanup changed)
;;

let test_resolution_is_durable_and_origin_scoped () =
  let base_path = temp_dir () in
  let keeper_name = "queue-origin" in
  let unrelated_keeper = "queue-unrelated" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input = `Assoc [ "target", `String "document"; "body", `String "hello" ] in
       let id = submit ~base_path ~keeper_name ~input in
       let result =
         AQ.resolve_with_policy
           ~id
           ~decision:AQ.Decision.Approve
           ()
       in
       (match result with
         | Ok () -> ()
         | Error error -> Alcotest.fail (AQ.resolve_error_to_string error)
       );
       Alcotest.(check bool) "pending removed" false
         (Option.is_some (AQ.get_pending_entry ~id));
       let resolution =
         match durable_resolution_opt ~base_path ~keeper_name ~approval_id:id with
         | None -> Alcotest.fail "origin Keeper did not receive durable resolution"
         | Some resolution -> resolution
       in
       (match resolution.decision with
        | Keeper_event_queue.Hitl_approved -> ()
        | Keeper_event_queue.Hitl_rejected _ | Keeper_event_queue.Hitl_edited _ ->
          Alcotest.fail "expected approved resolution");
       (match AQ.approved_resolution_request ~base_path ~id with
        | Ok (Some request) ->
          Alcotest.(check string) "journal keeper" keeper_name request.keeper_name;
          Alcotest.(check string) "journal operation" "external-effect" request.tool_name;
          Alcotest.(check bool) "journal complete input" true
            (Yojson.Safe.equal input request.input)
        | Ok None -> Alcotest.fail "approved journal was consumed before Gate use"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       Alcotest.(check bool) "unrelated Keeper receives no resolution" true
         (Option.is_none
            (durable_resolution_opt
               ~base_path
               ~keeper_name:unrelated_keeper
               ~approval_id:id));
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input:(`Assoc [ "target", `String "other" ])
        with
        | Ok AQ.Consumption_not_matching -> ()
        | Ok (AQ.Consumption_committed | AQ.Consumption_already_committed) ->
          Alcotest.fail "changed input consumed the exact grant"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input
        with
        | Ok AQ.Consumption_committed -> ()
        | Ok (AQ.Consumption_already_committed | AQ.Consumption_not_matching) ->
          Alcotest.fail "exact request did not consume its grant"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_cycle_grant_uses_exact_effect_and_is_consumed_once () =
  let base_path = temp_dir () in
  let keeper_name = "queue-one-shot-origin" in
  let input =
    `Assoc
      [ "target", `String "same-shape"
      ; "payload", `Assoc [ "value", `Int 1 ]
      ]
  in
  let continuation_channel =
    Keeper_continuation_channel.Dashboard { thread_id = "origin-thread" }
  in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let approval_id =
         submit_with_context
           ~turn_id:17
           ~task_id:"task-origin"
           ~continuation_channel
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       (match AQ.resolve ~id:approval_id ~decision:AQ.Decision.Approve with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let resolution =
         match
           durable_resolution_opt ~base_path ~keeper_name ~approval_id
         with
         | Some resolution -> resolution
         | None -> Alcotest.fail "approved resolution was not delivered"
       in
       AQ.For_testing.reset_runtime_state ();
       let report = install_exn ~base_path in
       Alcotest.(check int) "unconsumed grant restored" 1 report.replayed_deliveries;
       (match AQ.approved_resolution_state ~base_path ~id:approval_id with
        | Ok AQ.Resolution_unconsumed -> ()
        | Ok AQ.Resolution_consumed -> Alcotest.fail "restart lost the unconsumed grant"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       let grant =
         match Gate.cycle_grant_of_resolution resolution with
         | Some grant -> grant
         | None -> Alcotest.fail "approved resolution did not create a cycle grant"
       in
       let lease = lease_for_resolution resolution in
       (match
          Masc.Keeper_heartbeat_loop.settlement_of_cycle_outcome
            ~base_path
            ~settled_at:3.0
            ~stop_requested:false
            ~lease
            None
        with
        | Masc.Keeper_registry_event_queue.Requeue
            Masc.Keeper_registry_event_queue.Approval_grant_unconsumed ->
          ()
        | _ -> Alcotest.fail "unconsumed grant wake was acknowledged");
       let request ~input ~task_id : Gate.request =
         { keeper_name
         ; operation = "external-effect"
         ; input
         ; base_path
         ; causal_context =
             Some { Gate.turn_id = Some 99; snapshot = `Assoc [] }
         ; task_id
         ; continuation_channel = None
         }
       in
       let source_of = function
         | Gate.Allow { source } -> source
         | Gate.Deferred _ -> Alcotest.fail "keeper Always Allow unexpectedly deferred"
         | Gate.Unavailable reason ->
           Alcotest.fail (Gate.unavailable_reason_to_string reason)
       in
       (match
          Gate.decide
            ~cycle_grant:grant
            ~keeper_always_allow:true
            (request
               ~input:(`Assoc [ "target", `String "different" ])
               ~task_id:(Some "task-other"))
          |> source_of
        with
        | Gate.Keeper_always_allow -> ()
        | Gate.One_shot_resolution _ | Gate.Workspace_always_allow ->
          Alcotest.fail "different exact input consumed the grant");
       (match
          Gate.decide
            ~cycle_grant:grant
            ~keeper_always_allow:true
            (request
               ~input
               ~task_id:(Some "task-other"))
          |> source_of
        with
        | Gate.One_shot_resolution actual_id ->
          Alcotest.(check string) "exact approval id" approval_id actual_id
        | Gate.Keeper_always_allow
        | Gate.Workspace_always_allow ->
          Alcotest.fail "exact effect did not consume its one-shot grant");
       (match
          Gate.decide
            ~cycle_grant:grant
            ~keeper_always_allow:true
            (request ~input ~task_id:None)
          |> source_of
        with
        | Gate.Keeper_always_allow -> ()
        | Gate.One_shot_resolution _ | Gate.Workspace_always_allow ->
          Alcotest.fail "one-shot grant was consumed more than once");
       (match
          Masc.Keeper_heartbeat_loop.settlement_of_cycle_outcome
            ~base_path
            ~settled_at:4.0
            ~stop_requested:false
            ~lease
            None
        with
        | Masc.Keeper_registry_event_queue.Ack -> ()
        | _ -> Alcotest.fail "consumed grant wake was not acknowledged");
       AQ.For_testing.reset_runtime_state ();
       let _ = install_exn ~base_path in
       (match AQ.approved_resolution_state ~base_path ~id:approval_id with
        | Ok AQ.Resolution_consumed -> ()
        | Ok AQ.Resolution_unconsumed ->
          Alcotest.fail "consumed grant reappeared after restart"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_summary_updates_never_resolve_pending_request () =
  let base_path = temp_dir () in
  let keeper_name = "queue-summary-advisory" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let id = submit ~base_path ~keeper_name ~input:(`Assoc [ "request", `String "x" ]) in
       check_update "mark pending" true (AQ.mark_summary_pending ~id);
       check_update
         "duplicate judge worker rejected"
         false
         (AQ.mark_summary_pending ~id);
       let summary : AQ.hitl_context_summary =
         { summary_version = 2
         ; generated_at = Unix.gettimeofday ()
         ; model_run_id = "judge-run"
         ; context_summary = "The model recommends approval."
         ; key_questions = []
         ; judgment = AQ.Approve
         ; rationale = "Visible context supports the exact request."
         }
       in
       check_update "attach advisory judgment" true (AQ.attach_summary ~id summary);
       check_update "terminal summary cannot be replaced" false
         (AQ.attach_summary ~id { summary with judgment = AQ.Deny });
       check_update "terminal summary cannot become failure" false
         (AQ.mark_summary_failed ~id ~reason:"late failure" ~retryable:true);
       Alcotest.(check bool) "model judgment remains pending" true
         (Option.is_some (AQ.get_pending_entry ~id));
       Alcotest.(check bool) "resolved entry cannot be updated" true
         (match AQ.resolve ~id ~decision:(AQ.Decision.Reject "operator denied") with
          | Error error -> Alcotest.fail (AQ.resolve_error_to_string error)
          | Ok () ->
            (match AQ.attach_summary ~id summary with
             | Ok updated -> not updated
             | Error error -> Alcotest.fail (AQ.storage_error_to_string error))))
;;

let test_only_retryable_summary_failure_restarts () =
  let base_path = temp_dir () in
  let keeper_name = "queue-summary-retry" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let retryable_id =
         submit ~base_path ~keeper_name ~input:(`Assoc [ "request", `String "retry" ])
       in
       let terminal_id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "request", `String "terminal" ])
       in
       List.iter
         (fun id -> check_update "mark pending" true (AQ.mark_summary_pending ~id))
         [ retryable_id; terminal_id ];
       check_update
         "retryable failure"
         true
         (AQ.mark_summary_failed
            ~id:retryable_id
            ~reason:"interrupted"
            ~retryable:true);
       check_update
         "nonretryable failure"
         true
         (AQ.mark_summary_failed
            ~id:terminal_id
            ~reason:"terminal"
            ~retryable:false);
       check_update
         "retryable CAS restarts"
         true
         (AQ.restart_retryable_summary ~id:retryable_id);
       check_update
         "nonretryable state is unchanged"
         false
         (AQ.restart_retryable_summary ~id:terminal_id);
       (match AQ.get_pending_entry ~id:retryable_id with
        | Some { summary_status = AQ.Summary_pending; _ } -> ()
        | Some _ | None -> Alcotest.fail "retryable summary did not return to pending");
       reject_and_cleanup retryable_id;
       reject_and_cleanup terminal_id)
;;

let test_retryable_auto_judge_recovery_is_lane_local () =
  let base_path = temp_dir () in
  let keeper_a = "queue-retry-lane-a" in
  let keeper_b = "queue-retry-lane-b" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       let id_a =
         submit
           ~base_path
           ~keeper_name:keeper_a
           ~input:(`Assoc [ "request", `String "lane-a" ])
       in
       let id_b =
         submit
           ~base_path
           ~keeper_name:keeper_b
           ~input:(`Assoc [ "request", `String "lane-b" ])
       in
       List.iter
         (fun id -> check_update "mark pending" true (AQ.mark_summary_pending ~id))
         [ id_a; id_b ];
       check_update
         "lane a failed"
         true
         (AQ.mark_summary_failed ~id:id_a ~reason:"lane-a-original" ~retryable:true);
       check_update
         "lane b failed"
         true
         (AQ.mark_summary_failed ~id:id_b ~reason:"lane-b-original" ~retryable:true);
       let request : Gate.request =
         { keeper_name = keeper_a
         ; operation = "external-effect"
         ; input = `Assoc [ "request", `String "new-lane-a-activity" ]
         ; base_path
         ; causal_context = None
         ; task_id = None
         ; continuation_channel = None
         }
       in
       (match Gate.decide ~keeper_always_allow:true request with
        | Gate.Allow { source = Gate.Keeper_always_allow } -> ()
        | Gate.Allow _ | Gate.Deferred _ | Gate.Unavailable _ ->
          Alcotest.fail "lane activity did not retain Keeper Always Allow");
       (match AQ.get_pending_entry ~id:id_a with
        | Some
            { summary_status = AQ.Summary_failed { reason; retryable = true }
            ; _
            } ->
          Alcotest.(check bool)
            "same lane attempted retry"
            true
            (not (String.equal reason "lane-a-original"))
        | Some _ | None -> Alcotest.fail "same-lane retry state is not observable");
       (match AQ.get_pending_entry ~id:id_b with
        | Some
            { summary_status =
                AQ.Summary_failed { reason = "lane-b-original"; retryable = true }
            ; _
            } ->
          ()
        | Some _ | None ->
          Alcotest.fail "lane A activity retried another Keeper's judge");
       reject_and_cleanup id_a;
       reject_and_cleanup id_b;
       List.iter
         (fun (keeper_name, approval_id) ->
            match durable_resolution_opt ~base_path ~keeper_name ~approval_id with
            | Some resolution -> drop_resolution ~base_path ~keeper_name resolution
            | None -> Alcotest.fail "lane-local retry cleanup was not durable")
         [ keeper_a, id_a; keeper_b, id_b ])
;;

let test_decisive_summary_finalizes_after_restart () =
  let base_path = temp_dir () in
  let keeper_name = "queue-summary-finalize-restart" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       let id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "request", `String "finalize-after-restart" ])
       in
       check_update "mark pending" true (AQ.mark_summary_pending ~id);
       let summary : AQ.hitl_context_summary =
         { summary_version = 2
         ; generated_at = Unix.gettimeofday ()
         ; model_run_id = "judge-before-restart"
         ; context_summary = "The exact request is justified."
         ; key_questions = []
         ; judgment = AQ.Approve
         ; rationale = "Visible context supports this exact request."
         }
       in
       check_update "persist decisive summary" true (AQ.attach_summary ~id summary);
       AQ.For_testing.reset_runtime_state ();
       let _ = install_exn ~base_path in
       let report = Gate.resume_persisted_auto_judges ~base_path in
       Alcotest.(check int) "one recovery candidate" 1 report.requested;
       Alcotest.(check (list string)) "judgment finalized" [ id ] report.finalized_ids;
       Alcotest.(check int) "no worker restart" 0 (List.length report.started_ids);
       Alcotest.(check int) "no skipped recovery" 0 (List.length report.skipped_ids);
       Alcotest.(check int) "no recovery failure" 0 (List.length report.failures);
       Alcotest.(check bool) "pending removed" true
         (Option.is_none (AQ.get_pending_entry ~id));
       let resolution =
         match durable_resolution_opt ~base_path ~keeper_name ~approval_id:id with
         | Some resolution -> resolution
         | None -> Alcotest.fail "decisive summary did not reach origin Keeper"
       in
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_inflight_auto_judge_preserves_durable_restart_marker () =
  let base_path = temp_dir () in
  let keeper_name = "queue-restart-restore" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       let id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "target", `String "restart" ])
       in
       check_update "judge marked in flight" true (AQ.mark_summary_pending ~id);
       AQ.For_testing.reset_runtime_state ();
       Alcotest.(check int) "process state cleared" 0 (AQ.pending_count ());
       let report = install_exn ~base_path in
       Alcotest.(check int) "one pending restored" 1 report.loaded_pending;
       Alcotest.(check int) "no delivery replay" 0 report.replayed_deliveries;
       Alcotest.(check int)
         "no delivery replay failure"
         0
         (List.length report.delivery_replay_failures);
       (match AQ.get_pending_entry ~id with
        | None -> Alcotest.fail "same approval id was not restored"
        | Some entry ->
          Alcotest.(check bool)
            "in-flight state remains the durable restart marker"
            true
            (entry.summary_status = AQ.Summary_pending));
       let open Yojson.Safe.Util in
       let persisted = read_pending_snapshot ~base_path in
       let persisted_status =
         persisted
         |> member "pending"
         |> to_list
         |> List.hd
         |> member "summary_status"
       in
       Alcotest.(check bool)
         "restart marker remains persisted"
         true
         (Yojson.Safe.equal persisted_status (`String "pending"));
       reject_and_cleanup id;
       (match durable_resolution_opt ~base_path ~keeper_name ~approval_id:id with
        | Some resolution -> drop_resolution ~base_path ~keeper_name resolution
        | None -> Alcotest.fail "cleanup resolution was not durable"))
;;

let test_malformed_snapshot_fails_install_and_is_observed () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       write_pending_snapshot
         ~base_path
         (`Assoc
            [ "version", `Int 3
            ; "pending", `List [ `String "malformed-entry" ]
            ; "deliveries", `List []
            ]);
       let before =
         Masc.Otel_metric_store.metric_value_or_zero
           Masc.Otel_metric_store.metric_persistence_read_drops
           ~labels:[ "surface", "keeper_gate_pending"; "reason", "invalid_payload" ]
           ()
       in
       (match AQ.install_persistence ~base_path with
        | Ok _ -> Alcotest.fail "malformed snapshot must not install"
       | Error (AQ.Install_storage_failed _) -> ()
        );
       Alcotest.(check int) "no partial install" 0 (AQ.pending_count ());
       (match
          AQ.submit_pending
            ~keeper_name:"queue-invalid-store"
            ~tool_name:"external-effect"
            ~input:(`Assoc [ "target", `String "must-not-overwrite" ])
            ~base_path
            ()
        with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail "an invalid installed store must remain unavailable");
       let persisted = read_pending_snapshot ~base_path in
       Alcotest.(check bool) "invalid store is not overwritten" true
         (Yojson.Safe.equal
            persisted
            (`Assoc
               [ "version", `Int 3
               ; "pending", `List [ `String "malformed-entry" ]
               ; "deliveries", `List []
               ]));
       let after =
         Masc.Otel_metric_store.metric_value_or_zero
           Masc.Otel_metric_store.metric_persistence_read_drops
           ~labels:[ "surface", "keeper_gate_pending"; "reason", "invalid_payload" ]
           ()
       in
       Alcotest.(check bool) "malformed snapshot observed" true (after -. before >= 1.0))
;;

let test_persisted_delivery_replays_before_origin_wake () =
  let base_path = temp_dir () in
  let keeper_name = "queue-replay-origin" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       let id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "target", `String "replay" ])
       in
       let pending_entry =
         match read_pending_snapshot ~base_path with
         | `Assoc fields ->
           (match List.assoc_opt "pending" fields with
            | Some (`List [ entry ]) -> entry
            | _ -> Alcotest.fail "expected one persisted pending entry")
         | _ -> Alcotest.fail "expected pending snapshot object"
       in
       write_pending_snapshot
         ~base_path
         (`Assoc
            [ "version", `Int 3
            ; "pending", `List []
            ; ( "deliveries"
              , `List
                  [ `Assoc
                      [ "entry", pending_entry
                      ; "decision", `Assoc [ "kind", `String "approve" ]
                      ; "source", `String "human_operator"
                      ; "grant_consumed", `Bool false
                      ]
                  ] )
            ]);
       AQ.For_testing.reset_runtime_state ();
       let report = install_exn ~base_path in
       Alcotest.(check int) "no pending restored" 0 report.loaded_pending;
       Alcotest.(check int) "delivery replayed" 1 report.replayed_deliveries;
       let resolution =
         match durable_resolution_opt ~base_path ~keeper_name ~approval_id:id with
         | Some resolution -> resolution
         | None -> Alcotest.fail "replayed delivery did not reach origin queue"
       in
       let open Yojson.Safe.Util in
       let snapshot = read_pending_snapshot ~base_path in
       Alcotest.(check int) "unconsumed delivery remains journaled" 1
         (snapshot |> member "deliveries" |> to_list |> List.length);
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input:(`Assoc [ "target", `String "replay" ])
        with
        | Ok AQ.Consumption_committed -> ()
        | Ok (AQ.Consumption_already_committed | AQ.Consumption_not_matching) ->
          Alcotest.fail "replayed exact grant was not consumed"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       let snapshot = read_pending_snapshot ~base_path in
       Alcotest.(check int) "consumption tombstone remains explicit" 1
         (snapshot |> member "deliveries" |> to_list |> List.length);
       Alcotest.(check bool) "consumption tombstone is committed" true
         (snapshot
          |> member "deliveries"
          |> to_list
          |> List.hd
          |> member "grant_consumed"
          |> to_bool);
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_submit_surfaces_storage_failure () =
  let base_path = Filename.temp_file "queue-storage-error" "" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      try Sys.remove base_path with
      | Sys_error _ -> ())
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       match
         AQ.submit_pending
           ~keeper_name:"queue-storage-error"
           ~tool_name:"external-effect"
           ~input:(`Assoc [ "target", `String "x" ])
           ~base_path
           ()
       with
       | Ok _ -> Alcotest.fail "submission must not succeed without durable storage"
       | Error _ -> Alcotest.(check int) "memory not mutated" 0 (AQ.pending_count ()))
;;

let test_default_auto_judge_defers_without_blocking () =
  let base_path = temp_dir () in
  let keeper_name = "queue-default-auto-judge" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       let request : Gate.request =
         { keeper_name
         ; operation = "external-effect"
         ; input = `Assoc [ "target", `String "auto-judge" ]
         ; base_path
         ; causal_context =
             Some { Gate.turn_id = Some 9; snapshot = `Assoc [] }
         ; task_id = Some "task-auto-judge"
         ; continuation_channel = None
         }
       in
       match Gate.decide ~keeper_always_allow:false request with
       | Gate.Deferred { approval_id; reason = Gate.Auto_judge_unavailable detail } ->
         Alcotest.(check bool) "unavailable reason is explicit" true
           (String.length detail > 0);
         (match AQ.get_pending_entry ~id:approval_id with
          | Some { summary_status = AQ.Summary_failed { retryable = true; _ }; _ } ->
            ()
          | Some _ -> Alcotest.fail "Auto Judge failure was not durably retryable"
          | None -> Alcotest.fail "Auto Judge request was not durably queued");
         reject_and_cleanup approval_id
       | Gate.Deferred { reason = Gate.Judge_requested; _ } ->
         Alcotest.fail "test unexpectedly has a running server Auto Judge context"
       | Gate.Deferred { reason = (Gate.Human_requested | Gate.Mode_state_invalid _); _ } ->
         Alcotest.fail "default Gate mode did not select Auto Judge"
       | Gate.Allow _ -> Alcotest.fail "default Auto Judge allowed without a verdict"
       | Gate.Unavailable reason ->
         Alcotest.fail (Gate.unavailable_reason_to_string reason))
;;

let test_unavailable_cycle_grant_never_falls_through () =
  let base_path = temp_dir () in
  let keeper_name = "queue-stale-grant" in
  let input = `Assoc [ "target", `String "exact" ] in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       let approval_id = submit ~base_path ~keeper_name ~input in
       (match AQ.resolve ~id:approval_id ~decision:AQ.Decision.Approve with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let resolution =
         durable_resolution_opt ~base_path ~keeper_name ~approval_id
         |> require_some "approved resolution was not delivered"
       in
       let grant =
         Gate.cycle_grant_of_resolution resolution
         |> require_some "approved resolution lacked grant"
       in
       let request : Gate.request =
         { keeper_name
         ; operation = "external-effect"
         ; input
         ; base_path
         ; causal_context = None
         ; task_id = None
         ; continuation_channel = None
         }
       in
       AQ.For_testing.reset_runtime_state ();
       (match Gate.decide ~cycle_grant:grant ~keeper_always_allow:true request with
        | Gate.Unavailable (Gate.Approval_grant_unavailable _) -> ()
        | Gate.Allow _ ->
          Alcotest.fail "unconsumed grant failure fell through to Always Allow"
        | Gate.Deferred _ ->
          Alcotest.fail "unconsumed grant failure created a second approval"
        | Gate.Unavailable _ ->
          Alcotest.fail "unexpected unavailable reason for unreadable grant");
       ignore (install_exn ~base_path);
       (match Gate.decide ~cycle_grant:grant ~keeper_always_allow:false request with
        | Gate.Allow { source = Gate.One_shot_resolution actual } ->
          Alcotest.(check string) "grant remains unconsumed" approval_id actual
        | Gate.Allow _ -> Alcotest.fail "restored exact grant used the wrong source"
        | Gate.Deferred _ -> Alcotest.fail "restored exact grant did not authorize"
        | Gate.Unavailable reason ->
          Alcotest.fail (Gate.unavailable_reason_to_string reason));
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_nonapproved_resolution_payload_is_delivered () =
  let base_path = temp_dir () in
  let keeper_name = "queue-resolution-payload" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       let reject_id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "target", `String "reject" ])
       in
       let rationale = "Use the project-scoped target." in
       (match
          AQ.resolve
            ~id:reject_id
            ~decision:(AQ.Decision.Reject rationale)
        with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let rejected =
         durable_resolution_opt
           ~base_path
           ~keeper_name
           ~approval_id:reject_id
         |> require_some "rejection resolution was not delivered"
       in
       (match rejected.decision with
        | Keeper_event_queue.Hitl_rejected actual ->
          Alcotest.(check string) "rejection rationale" rationale actual
        | _ -> Alcotest.fail "rejection resolution lost its typed decision");
       Alcotest.(check bool)
         "rejection is not a grant"
         true
         (Option.is_none (Gate.cycle_grant_of_resolution rejected));
       let edit_id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "target", `String "before" ])
       in
       let edited_input =
         `Assoc [ "target", `String "after"; "confirmed", `Bool true ]
       in
       (match AQ.resolve ~id:edit_id ~decision:(AQ.Decision.Edit edited_input) with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let edited =
         durable_resolution_opt ~base_path ~keeper_name ~approval_id:edit_id
         |> require_some "edited resolution was not delivered"
       in
       (match edited.decision with
        | Keeper_event_queue.Hitl_edited actual ->
          Alcotest.(check bool)
            "edited input"
            true
            (Yojson.Safe.equal edited_input actual)
        | _ -> Alcotest.fail "edited resolution lost its typed input");
       Alcotest.(check bool)
         "edit is not a grant"
         true
         (Option.is_none (Gate.cycle_grant_of_resolution edited));
       drop_resolution ~base_path ~keeper_name rejected;
       drop_resolution ~base_path ~keeper_name edited)
;;

let () =
  Alcotest.run
    "Keeper_approval_queue"
    [ ( "nonhierarchical queue"
      , [ Alcotest.test_case
            "durable lock serializes Eio fibers"
            `Quick
            test_pending_store_lock_serializes_eio_fibers
        ; Alcotest.test_case
            "install serializes snapshot read with mutation"
            `Quick
            test_install_serializes_snapshot_read_with_same_base_mutation
        ; Alcotest.test_case
            "submit is nonblocking and exact"
            `Quick
            test_submit_is_nonblocking_and_exactly_deduplicated
        ; Alcotest.test_case
            "dedup keeps distinct origins"
            `Quick
            test_dedup_never_merges_distinct_origins
        ; Alcotest.test_case
            "resolution wakes only origin"
            `Quick
            test_resolution_is_durable_and_origin_scoped
        ; Alcotest.test_case
            "cycle grant binds origin and is consumed once"
            `Quick
            test_cycle_grant_uses_exact_effect_and_is_consumed_once
        ; Alcotest.test_case
            "summary is advisory"
            `Quick
            test_summary_updates_never_resolve_pending_request
        ; Alcotest.test_case
            "only retryable summary failure restarts"
            `Quick
            test_only_retryable_summary_failure_restarts
        ; Alcotest.test_case
            "retryable Auto Judge recovery is lane-local"
            `Quick
            test_retryable_auto_judge_recovery_is_lane_local
        ; Alcotest.test_case
            "decisive summary finalizes after restart"
            `Quick
            test_decisive_summary_finalizes_after_restart
        ; Alcotest.test_case
            "interrupted judge keeps restart marker"
            `Quick
            test_inflight_auto_judge_preserves_durable_restart_marker
        ; Alcotest.test_case
            "malformed snapshot is explicit"
            `Quick
            test_malformed_snapshot_fails_install_and_is_observed
        ; Alcotest.test_case
            "delivery journal replays"
            `Quick
            test_persisted_delivery_replays_before_origin_wake
        ; Alcotest.test_case
            "storage failure is returned"
            `Quick
            test_submit_surfaces_storage_failure
        ; Alcotest.test_case
            "default Auto Judge defers without blocking"
            `Quick
            test_default_auto_judge_defers_without_blocking
        ; Alcotest.test_case
            "unavailable grant never falls through"
            `Quick
            test_unavailable_cycle_grant_never_falls_through
        ; Alcotest.test_case
            "non-approved resolution payload is delivered"
            `Quick
            test_nonapproved_resolution_payload_is_delivered
        ] )
    ]
;;
