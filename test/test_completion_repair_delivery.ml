(** Exercise the durable gap between verdict commit and producer delivery.
    No completion-agent observer is installed: reconciliation must reconstruct
    its work from a fresh authoritative backlog read. *)
module D = Masc_domain
module W = Workspace_core
module Outbox = Workspace_task_rejection_outbox
module Wake = Masc.Completion_authority_wakeup
module Queue = Keeper_event_queue_persistence

let () = Mirage_crypto_rng_unix.use_default ()

let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let workspace_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (D.masc_error_to_string error)

let with_workspace_runtime f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let base_path = Filename.temp_dir "masc-completion-repair-" "" in
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.on_release sw (fun () ->
        Fs_compat.clear_fs ();
        Masc_test_deps.cleanup_test_workspace base_path);
      let config = W.default_config base_path in
      ignore (W.init config ~agent_name:(Some "repair-producer"));
      ignore (W.add_task config ~title:"recover rejected work" ~priority:1
                ~description:"rejection must reach the producer after restart");
      f ~sw ~clock:(Eio.Stdenv.clock env) config))

let with_workspace f =
  with_workspace_runtime (fun ~sw:_ ~clock:_ config -> f config)

let producer = "repair-producer"
let task_id = "task-001"
let reason = "the deployed destination does not contain the submitted change"
let system = D.System_llm_agent { agent_run_id = "repair-verifier-run" }
let human = D.Human_operator { operator_id = "repair-operator" }

let persist_producer config =
  let meta = ok (Masc_test_deps.meta_of_json_fixture
                   (`Assoc [ "name", `String producer ])) in
  ok (Masc.Keeper_fs.save_json_atomic
        (Masc.Keeper_types_profile.keeper_meta_path config producer)
        (Masc.Keeper_meta_json.meta_to_json meta))

let prepare_submission config verification_id =
  let backlog = ok (Workspace_backlog.read_backlog_r config) in
  let tasks = List.map (fun (task : D.task) ->
    { task with task_status = D.AwaitingVerification
        { assignee = producer; started_at = "2026-09-09T00:00:00Z"
        ; submitted_at = D.now_iso (); intent = D.Complete_task; verification_id
        } }) backlog.tasks in
  W.write_backlog config { backlog with tasks }

let commit config ~authority ~verification_id verdict =
  ignore (workspace_ok (W.commit_verdict_r config ~authority ~verdict
                         ~task_id ~verification_id ()))

let pending config = ok (Outbox.pending config)
let queue config =
  ok (Queue.load_result ~base_path:config.W.base_path ~keeper_name:producer)
  |> Keeper_event_queue.to_list

let check_pending config expected =
  Alcotest.(check int) "durable obligations" expected (List.length (pending config))

let reconcile config ~delivered ~retained =
  let report = ok (Wake.reconcile_pending ~config) in
  Alcotest.(check int) "delivered" delivered report.Wake.delivered;
  Alcotest.(check int) "retained" retained report.Wake.retained

let check_rejection config ~verification_id ~authority =
  match queue config with
  | [ { payload = Keeper_event_queue.Completion_authority_rejected rejection; _ } ] ->
    Alcotest.(check string) "task identity" task_id rejection.car_task_id;
    Alcotest.(check string) "verification identity" verification_id
      rejection.car_verification_id;
    Alcotest.(check string) "exact reason" reason rejection.car_reason;
    Alcotest.(check bool) "typed authority" true
      (authority = rejection.car_authority)
  | events -> Alcotest.failf "expected one typed rejection, got %d events"
                (List.length events)

let test_commit_gap authority () =
  with_workspace (fun config ->
    persist_producer config;
    let verification_id = "vrf-crash-after-commit" in
    prepare_submission config verification_id;
    commit config ~authority ~verification_id (D.Verdict_rejected { reason });
    (* Reload both configuration and backlog, without retaining a notification. *)
    let recovered = W.default_config config.W.base_path in
    (match (ok (Workspace_backlog.read_backlog_r recovered)).tasks with
     | [ { task_status = D.InProgress { assignee; _ }; _ } ] ->
       Alcotest.(check string) "producer still owns repair" producer assignee
     | _ -> Alcotest.fail "rejection must return work to InProgress");
    (match pending recovered with
     | [ obligation ] ->
       Alcotest.(check string) "outbox verification" verification_id
         obligation.D.verification_id;
       Alcotest.(check string) "outbox producer" producer obligation.D.producer;
       Alcotest.(check bool) "outbox authority" true
         (authority = obligation.D.authority)
     | _ -> Alcotest.fail "committed rejection has no durable delivery obligation");
    Alcotest.(check int) "no observer was needed at commit" 0
      (List.length (queue recovered));
    reconcile recovered ~delivered:1 ~retained:0;
    check_pending recovered 0;
    check_rejection recovered ~verification_id ~authority;
    reconcile recovered ~delivered:0 ~retained:0;
    check_rejection recovered ~verification_id ~authority)

let snapshot_path config =
  Filename.concat
    (Filename.concat
       (Common.keepers_runtime_dir_of_base ~base_path:config.W.base_path) producer)
    Queue.snapshot_filename

let test_queue_failure_retains_obligation () =
  with_workspace (fun config ->
    persist_producer config;
    let verification_id = "vrf-queue-write-failed" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    let path = snapshot_path config in
    Fs_compat.mkdir_p (Filename.dirname path);
    Out_channel.with_open_text path (fun out -> output_string out "{corrupt queue");
    reconcile config ~delivered:0 ~retained:1;
    check_pending config 1;
    Alcotest.(check string) "failed queue read preserves corrupt authority"
      "{corrupt queue" (In_channel.with_open_text path In_channel.input_all);
    (* Remove only our injected corrupt fixture, then retry the same obligation. *)
    Sys.remove path;
    reconcile config ~delivered:1 ~retained:0;
    check_pending config 0;
    check_rejection config ~verification_id ~authority:system)

let test_enqueue_before_ack_is_idempotent () =
  with_workspace (fun config ->
    persist_producer config;
    let verification_id = "vrf-crash-after-enqueue" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    (* Simulate a process stopping after durable enqueue and before outbox ack. *)
    (match Wake.wake_rejected_producer ~config ~producer ~task_id ~verification_id
             ~reason ~authority:system with
     | Wake.Signaled _ | Wake.Durable_deferred _ | Wake.Durable_wake_failed _ -> ()
     | _ -> Alcotest.fail "fixture failed to durably enqueue rejection");
    check_pending config 1;
    check_rejection config ~verification_id ~authority:system;
    reconcile (W.default_config config.W.base_path) ~delivered:1 ~retained:0;
    check_pending config 0;
    check_rejection config ~verification_id ~authority:system)

let test_approval_has_no_repair_obligation () =
  with_workspace (fun config ->
    persist_producer config;
    let verification_id = "vrf-approved" in
    prepare_submission config verification_id;
    commit config ~authority:human ~verification_id D.Verdict_approved;
    check_pending config 0;
    reconcile config ~delivered:0 ~retained:0;
    Alcotest.(check int) "approval has no rejection stimulus" 0
      (List.length (queue config)))

let test_resubmit_supersedes_and_stale_ack_preserves_new_rejection () =
  with_workspace (fun config ->
    persist_producer config;
    let old_id = "vrf-old-rejection" in
    prepare_submission config old_id;
    commit config ~authority:system ~verification_id:old_id
      (D.Verdict_rejected { reason });
    check_pending config 1;
    ignore (workspace_ok (W.transition_task_r config ~agent_name:producer ~task_id
                           ~action:D.Submit_for_verification
                           ~prepare_verification_request:(fun ~task ~assignee
                               ~verification_id ~claim:_ ->
                             Masc.Verification.create_request
                               ~base_path:config.W.base_path ~request_id:verification_id
                               ~task_id:task.D.id ~output:(`Assoc []) ~criteria:[]
                               ~worker:assignee () |> Result.map (fun _ -> ()))
                           ~notes:"note:repaired destination and resubmitted evidence" ()));
    let new_id = match (ok (Workspace_backlog.read_backlog_r config)).tasks with
      | [ { task_status = D.AwaitingVerification { verification_id; _ }; _ } ] ->
        verification_id
      | _ -> Alcotest.fail "resubmission must create a new verification" in
    Alcotest.(check bool) "new submission identity" true (old_id <> new_id);
    check_pending config 0;
    (match W.commit_verdict_r config ~authority:system
             ~verdict:(D.Verdict_rejected { reason }) ~task_id
             ~verification_id:old_id () with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "superseded verdict was allowed to commit");
    commit config ~authority:human ~verification_id:new_id (D.Verdict_rejected { reason });
    ok (Outbox.acknowledge config ~task_id ~verification_id:old_id);
    check_pending config 1;
    reconcile config ~delivered:1 ~retained:0;
    check_rejection config ~verification_id:new_id ~authority:human)

let test_corrupt_explicit_outbox_is_not_empty () =
  with_workspace (fun config ->
    let path = Workspace_backlog.backlog_path config in
    let fields = Yojson.Safe.from_file path |> Yojson.Safe.Util.to_assoc in
    let corrupt = `Assoc (("pending_completion_rejections", `String "corrupt")
                          :: List.remove_assoc "pending_completion_rejections" fields) in
    Yojson.Safe.to_file path corrupt;
    (match Outbox.pending config with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "malformed outbox was silently treated as empty");
    (match Wake.reconcile_pending ~config with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "reconciliation accepted malformed authoritative backlog");
    Alcotest.(check bool) "corrupt backlog preserved" true
      (Yojson.Safe.from_file path = corrupt))

let test_daemon_delivery ~start_before_commit () =
  with_workspace_runtime (fun ~sw ~clock config ->
    persist_producer config;
    let verification_id = "vrf-native-daemon-repair" in
    let reviewer_calls = ref 0 in
    let previous_reviewer =
      Atomic.get Masc.Task.Anti_rationalization.run_llm_reviewer_fn in
    Eio.Switch.on_release sw (fun () ->
      Atomic.set Masc.Task.Anti_rationalization.run_llm_reviewer_fn previous_reviewer);
    Atomic.set Masc.Task.Anti_rationalization.run_llm_reviewer_fn
      (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ?goal_blocks:_
          ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
          ~on_runtime_attempt_error:_ () ->
        incr reviewer_calls;
        Alcotest.fail "delivery recovery must not invoke a model");
    if start_before_commit then
      Masc.Completion_authority_agent.start ~sw ~clock ~config;
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    if not start_before_commit then
      Masc.Completion_authority_agent.start ~sw ~clock ~config;
    (* Poll only the durable result, never manually reconcile. The bound belongs
       to this test's failure detection, not the product's recovery policy. *)
    Eio.Time.with_timeout_exn clock 5.0 (fun () ->
      let rec await_delivery () =
        if pending config = [] && List.length (queue config) = 1 then ()
        else (Eio.Time.sleep clock 0.01; await_delivery ())
      in
      await_delivery ());
    check_rejection config ~verification_id ~authority:system;
    check_pending config 0;
    Alcotest.(check int) "repair delivery uses no model" 0 !reviewer_calls)

let () =
  Alcotest.run "Completion repair delivery"
    [ "durable verdict delivery",
      [ Alcotest.test_case "system commit survives missing consumer" `Quick (test_commit_gap system)
      ; Alcotest.test_case "human commit survives missing consumer" `Quick (test_commit_gap human)
      ; Alcotest.test_case "daemon startup recovers committed repair" `Quick
          (test_daemon_delivery ~start_before_commit:false)
      ; Alcotest.test_case "running daemon receives commit hook" `Quick
          (test_daemon_delivery ~start_before_commit:true)
      ; Alcotest.test_case "queue failure retains and retries" `Quick test_queue_failure_retains_obligation
      ; Alcotest.test_case "enqueue before acknowledgement deduplicates" `Quick test_enqueue_before_ack_is_idempotent
      ; Alcotest.test_case "approval creates no repair" `Quick test_approval_has_no_repair_obligation
      ; Alcotest.test_case "resubmission and stale acknowledgement" `Quick test_resubmit_supersedes_and_stale_ack_preserves_new_rejection
      ; Alcotest.test_case "corrupt outbox fails closed" `Quick test_corrupt_explicit_outbox_is_not_empty
      ] ]
