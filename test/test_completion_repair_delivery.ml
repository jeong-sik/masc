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
  (* The verdict hook is part of the contract under test: the approval twin
     wake reaches the producer queue through the installed runtime adapter
     (Workspace_metric_hooks), not through any test-local stub. *)
  Masc.Workspace_metric_hooks.install ();
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
        ; submitted_at = D.now_iso (); verification_id
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

let reconcile ?(unroutable = 0) config ~delivered ~retained =
  let report = ok (Wake.reconcile_pending ~config) in
  Alcotest.(check int) "delivered" delivered report.Wake.delivered;
  Alcotest.(check int) "unroutable" unroutable report.Wake.unroutable;
  Alcotest.(check int) "retained" retained report.Wake.retained

let check_rejections config ~verification_ids ~authority =
  let actual_ids = List.map (fun stimulus ->
    match stimulus.Keeper_event_queue.payload with
    | Keeper_event_queue.Completion_authority_rejected rejection ->
      Alcotest.(check string) "task identity" task_id rejection.car_task_id;
      Alcotest.(check string) "exact reason" reason rejection.car_reason;
      Alcotest.(check bool) "typed authority" true
        (authority = rejection.car_authority);
      rejection.car_verification_id
    | _ -> Alcotest.fail "expected only typed rejection stimuli") (queue config) in
  Alcotest.(check (list string)) "exact verification identities without duplicates"
    (List.sort String.compare verification_ids) (List.sort String.compare actual_ids)

let check_rejection config ~verification_id ~authority =
  check_rejections config ~verification_ids:[verification_id] ~authority

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

let only_task config =
  match (ok (Workspace_backlog.read_backlog_r config)).tasks with
  | [ task ] -> task
  | tasks ->
    Alcotest.failf "the fixture holds exactly one task, found %d" (List.length tasks)

let set_tasks config tasks =
  let backlog = ok (Workspace_backlog.read_backlog_r config) in
  W.write_backlog config { backlog with tasks }

(* An MCP client that claimed and submitted the Task (codex-mcp-client in
   the 2026-09-12 fleet) has no registry entry and no Keeper meta, so no queue
   under its name is ever read. The obligation used to be retained and retried
   every interval for good: nine of them logged 12,960 errors a day. Ending the
   obligation alone still left the Task held by a name that will never act, so
   the Task comes back to the backlog with the verdict on it. *)
let test_rejection_with_no_keeper_returns_the_task_to_todo () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-producer" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    check_pending config 1;
    reconcile config ~delivered:0 ~unroutable:1 ~retained:0;
    check_pending config 0;
    Alcotest.(check int) "no queue is written under a name no Keeper reads" 0
      (List.length (queue config));
    (match only_task config with
     | { task_status = D.Todo; handoff_context = Some handoff; _ } ->
       Alcotest.(check (option string)) "the verdict's reason stays on the Task"
         (Some reason) handoff.reason;
       Alcotest.(check (list string)) "the verification id travels with it"
         [ verification_id ] handoff.evidence_refs;
       Alcotest.(check (option string)) "the deciding authority is the releaser"
         (Some "repair-verifier-run") handoff.updated_by;
       (* The three fields above are also what the verdict's own rejection
          handoff carries, so they hold whether or not the release writes one.
          These do not: they are the release saying why the task came back and
          that anyone may take it. *)
       Alcotest.(check bool) "the note says the verdict had nowhere to go" true
         (Astring.String.is_infix ~affix:"no producer Keeper" handoff.summary);
       Alcotest.(check (option string)) "and what the next agent does with it"
         (Some "Any agent may claim this task and answer the rejection")
         handoff.next_step;
       Alcotest.(check bool) "the task is offered rather than held" true
         (handoff.reclaim_policy = Some D.Allow_reclaim)
     | { task_status; _ } ->
       Alcotest.failf "a rejection with no Keeper must release the Task, found %s"
         (D.task_status_to_string task_status));
    reconcile config ~delivered:0 ~retained:0)

(* A rejection returns work to [InProgress], so that is the state every case
   above starts from. [Claimed] reaches the same release through the same arm
   and nothing had walked it: a task claimed but not started, whose claimer is
   gone, is stuck exactly as hard. *)
let test_a_claimed_task_is_released_too () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-claimed" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    let backlog = ok (Workspace_backlog.read_backlog_r config) in
    let tasks =
      List.map
        (fun (task : D.task) ->
           { task with
             task_status =
               D.Claimed { assignee = producer; claimed_at = "2026-09-09T00:00:00Z" }
           })
        backlog.tasks
    in
    W.write_backlog config { backlog with tasks };
    reconcile config ~delivered:0 ~unroutable:1 ~retained:0;
    match only_task config with
    | { task_status = D.Todo; _ } -> ()
    | { task_status; _ } ->
      Alcotest.failf "a claimed task with no actor must be released, found %s"
        (D.task_status_to_string task_status))

(* The releaser is read off the obligation's authority, and an operator's
   verdict is recorded as an operator's release. A system verdict is what every
   other case here carries, so this is the other half of that mapping. *)
let test_an_operator_verdict_releases_as_the_operator () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-operator-verdict" in
    prepare_submission config verification_id;
    commit config ~authority:human ~verification_id (D.Verdict_rejected { reason });
    reconcile config ~delivered:0 ~unroutable:1 ~retained:0;
    match only_task config with
    | { task_status = D.Todo; handoff_context = Some handoff; _ } ->
      Alcotest.(check (option string)) "the operator who decided is the releaser"
        (Some "repair-operator") handoff.updated_by
    | { task_status; _ } ->
      Alcotest.failf "an operator's rejection releases too, found %s"
        (D.task_status_to_string task_status))

(* The status is half the guard and the assignee is the other half. A task
   that stayed [InProgress] but changed hands belongs to whoever holds it now,
   and releasing it would take work away from an agent that is still there. *)
let test_a_task_held_by_someone_else_is_not_released () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-handed-over" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    let backlog = ok (Workspace_backlog.read_backlog_r config) in
    let tasks =
      List.map
        (fun (task : D.task) ->
           { task with
             task_status =
               D.InProgress { assignee = "someone-else"; started_at = "2026-09-09T00:00:00Z" }
           })
        backlog.tasks
    in
    W.write_backlog config { backlog with tasks };
    let before = only_task config in
    reconcile config ~delivered:0 ~unroutable:1 ~retained:0;
    check_pending config 0;
    Alcotest.(check string) "the new holder keeps the task"
      (D.show_task before) (D.show_task (only_task config)))

(* The route is read before the backlog lock is taken. A Keeper meta landing at
   the producer's name in between means the verdict can be delivered after all,
   and releasing the task then would lose the delivery the queue now accepts.
   Called directly: the race is exactly the window reconcile cannot open. *)
let test_a_queue_that_appears_before_the_lock_keeps_the_task () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-then-keeper" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    let before = only_task config in
    match
      W.release_unroutable_rejected_task_r config ~authority:system ~task_id
        ~producer ~verification_id ~reason
        ~still_unroutable:(fun () -> Ok false)
        ()
    with
    | Ok W.Producer_became_routable ->
      Alcotest.(check string) "the task waits for the delivery it can now have"
        (D.show_task before) (D.show_task (only_task config));
      check_pending config 1
    | Ok _ -> Alcotest.fail "a routable producer must not have its task released"
    | Error error -> Alcotest.fail (D.masc_error_to_string error))

(* Release precedes acknowledgement. A release that fails must therefore leave
   the obligation standing: if the order were the other way, this obligation
   would be gone and the task would stay held by a name that will never act. *)
let test_a_failed_release_keeps_the_obligation () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-unwritable" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    let backlog_dir = Filename.dirname (Workspace_backlog.backlog_path config) in
    let mode = (Unix.stat backlog_dir).Unix.st_perm in
    Unix.chmod backlog_dir 0o555;
    let report = ok (Wake.reconcile_pending ~config) in
    Unix.chmod backlog_dir mode;
    if report.Wake.unroutable > 0
    then
      Alcotest.fail
        "the fixture could not make the backlog unwritable, so this case proves \
         nothing about the order";
    Alcotest.(check int) "a failed release is kept for the next interval" 1
      report.Wake.retained;
    check_pending config 1;
    (match only_task config with
     | { task_status = D.InProgress _; _ } -> ()
     | { task_status; _ } ->
       Alcotest.failf "a failed release must not move the task, found %s"
         (D.task_status_to_string task_status));
    reconcile config ~delivered:0 ~unroutable:1 ~retained:0;
    check_pending config 0)

(* A release that fails the same way every interval is the shape #36461
   removed. An obligation whose task id is not a task id can never be released,
   so it ends here with the reason on the record rather than being retried for
   good. *)
let test_a_release_that_can_never_succeed_ends_the_obligation () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-unusable-id" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    let backlog = ok (Workspace_backlog.read_backlog_r config) in
    let broken =
      List.map
        (fun (item : D.pending_completion_rejection) ->
           { item with task_id = "task/001" })
        backlog.pending_completion_rejections
    in
    W.write_backlog config { backlog with pending_completion_rejections = broken };
    reconcile config ~delivered:0 ~unroutable:1 ~retained:0;
    check_pending config 0)

(* Between the verdict and this delivery the same producer name can submit
   again. That submission is the current answer, so the obligation ends without
   touching the Task: releasing it would throw away work nobody rejected. *)
let test_release_leaves_a_task_that_moved_on () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-resubmitted" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    prepare_submission config "vrf-no-keeper-resubmitted-again";
    let before = only_task config in
    reconcile config ~delivered:0 ~unroutable:1 ~retained:0;
    check_pending config 0;
    Alcotest.(check string) "the newer submission is left exactly as it stands"
      (D.show_task before) (D.show_task (only_task config)))

(* The Task can be gone by the time the obligation is worked: nothing to
   release, and retrying can never find it again. *)
let test_release_discharges_when_the_task_is_gone () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-deleted-task" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    set_tasks config [];
    reconcile config ~delivered:0 ~unroutable:1 ~retained:0;
    check_pending config 0)

(* Release precedes acknowledgement, so a crash between the two brings the
   obligation back. The replay reads the status again, finds the Task no longer
   held by the producer, and ends the obligation without a second mutation. *)
let test_release_before_acknowledgement_replays_idempotently () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-replay" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    let obligation =
      match pending config with
      | [ item ] -> item
      | items -> Alcotest.failf "one obligation, found %d" (List.length items)
    in
    reconcile config ~delivered:0 ~unroutable:1 ~retained:0;
    let released = only_task config in
    let backlog = ok (Workspace_backlog.read_backlog_r config) in
    W.write_backlog config { backlog with pending_completion_rejections = [ obligation ] };
    reconcile config ~delivered:0 ~unroutable:1 ~retained:0;
    check_pending config 0;
    Alcotest.(check string) "the replay leaves the released Task untouched"
      (D.show_task released) (D.show_task (only_task config)))

(* A file at the Keeper meta path that this binary does not decode is a Keeper
   whose meta the boot path re-materialises, not an absent one. It must not be
   discharged as unroutable: the obligation waits and reaches the queue once
   the meta reads again. *)
let test_undecodable_producer_meta_retains_obligation () =
  with_workspace (fun config ->
    let verification_id = "vrf-undecodable-producer-meta" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    let meta_path = Masc.Keeper_types_profile.keeper_meta_path config producer in
    Fs_compat.mkdir_p (Filename.dirname meta_path);
    Out_channel.with_open_text meta_path (fun out -> output_string out "[]");
    reconcile config ~delivered:0 ~unroutable:0 ~retained:1;
    check_pending config 1;
    persist_producer config;
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
      (List.length
         (List.filter
            (fun stimulus ->
               match stimulus.Keeper_event_queue.payload with
               | Keeper_event_queue.Task_outcome _ -> false
               | _ -> true)
            (queue config)));
    (* The approval still reaches the producer in its own right: the twin wake
       carries the typed outcome, with no repair obligation behind it. *)
    Alcotest.(check (list string)) "approval wake carries the exact verification"
      [ verification_id ]
      (List.filter_map
         (fun stimulus ->
            match stimulus.Keeper_event_queue.payload with
            | Keeper_event_queue.Task_outcome outcome ->
              Alcotest.(check string) "approval task identity" task_id
                outcome.to_task_id;
              Alcotest.(check bool) "typed authority" true
                (human = outcome.to_authority);
              Some outcome.to_verification_id
            | _ -> None)
         (queue config)))

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
    (* Poll only the durable result, never manually reconcile. The bound belongs
       to this test's failure detection, not the product's recovery policy. *)
    let await_delivery expected_count =
      Eio.Time.with_timeout_exn clock 5.0 (fun () ->
        let rec await () =
          if pending config = [] && List.length (queue config) = expected_count then ()
          else (Eio.Time.sleep clock 0.01; await ())
        in
        await ())
    in
    let boot_id = "vrf-native-daemon-boot-sentinel" in
    if start_before_commit then (
      prepare_submission config boot_id;
      commit config ~authority:system ~verification_id:boot_id
        (D.Verdict_rejected { reason });
      Masc.Completion_authority_agent.start ~sw ~clock ~config;
      await_delivery 1;
      check_rejection config ~verification_id:boot_id ~authority:system;
      (* The daemon scans boot review scopes before delivering this sentinel.
         Its queue row and acknowledged outbox prove that startup recovery has
         finished before the second commit. Only a fresh hook wake can now
         deliver the second rejection. Leave the first row intact and verify
         both exact identities, so no test-side queue mutation drives delivery. *)
      check_pending config 0);
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    if not start_before_commit then
      Masc.Completion_authority_agent.start ~sw ~clock ~config;
    let verification_ids =
      if start_before_commit then [boot_id; verification_id] else [verification_id] in
    await_delivery (List.length verification_ids);
    check_rejections config ~verification_ids ~authority:system;
    check_pending config 0;
    Alcotest.(check int) "repair delivery uses no model" 0 !reviewer_calls)

let () =
  Alcotest.run "Completion repair delivery"
    [ "durable verdict delivery",
      [ Alcotest.test_case "system commit survives missing consumer" `Quick (test_commit_gap system)
      ; Alcotest.test_case "human commit survives missing consumer" `Quick (test_commit_gap human)
      ; Alcotest.test_case "a rejection with no Keeper to deliver to returns the task to todo"
          `Quick test_rejection_with_no_keeper_returns_the_task_to_todo
      ; Alcotest.test_case "a task that moved on is left alone"
          `Quick test_release_leaves_a_task_that_moved_on
      ; Alcotest.test_case "a task held by someone else is left alone"
          `Quick test_a_task_held_by_someone_else_is_not_released
      ; Alcotest.test_case "a claimed task is released too"
          `Quick test_a_claimed_task_is_released_too
      ; Alcotest.test_case "an operator verdict releases as the operator"
          `Quick test_an_operator_verdict_releases_as_the_operator
      ; Alcotest.test_case "a queue that appears before the lock keeps the task"
          `Quick test_a_queue_that_appears_before_the_lock_keeps_the_task
      ; Alcotest.test_case "a failed release keeps the obligation"
          `Quick test_a_failed_release_keeps_the_obligation
      ; Alcotest.test_case "a release that can never succeed ends the obligation"
          `Quick test_a_release_that_can_never_succeed_ends_the_obligation
      ; Alcotest.test_case "a deleted task discharges the obligation"
          `Quick test_release_discharges_when_the_task_is_gone
      ; Alcotest.test_case "release before acknowledgement replays idempotently"
          `Quick test_release_before_acknowledgement_replays_idempotently
      ; Alcotest.test_case "an undecodable producer meta retains the obligation"
          `Quick test_undecodable_producer_meta_retains_obligation
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
