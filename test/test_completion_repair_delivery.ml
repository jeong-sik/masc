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
  (* Install the production notification adapter. Neither verdict depends on
     this best-effort projection for its durable delivery obligation. *)
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

let submit_repair config =
  ignore (workspace_ok (W.transition_task_r config ~agent_name:producer ~task_id
    ~action:D.Submit_for_verification
    ~prepare_verification_request:(fun ~task ~assignee ~verification_id ~claim:_ ->
      Masc.Verification.create_request ~base_path:config.W.base_path
        ~request_id:verification_id ~task_id:task.D.id ~output:(`Assoc [])
        ~criteria:[] ~worker:assignee () |> Result.map (fun _ -> ()))
    ~notes:"note:repaired destination and resubmitted evidence" ()));
  match (ok (Workspace_backlog.read_backlog_r config)).tasks with
  | [{task_status=D.AwaitingVerification {verification_id;_};_}] -> verification_id
  | [] | _ :: _ :: _
  | [{task_status=(D.Todo | D.Claimed _ | D.InProgress _ | D.Done _ | D.Cancelled _);_}] ->
    Alcotest.fail "resubmission must create a new verification"

let standing config ~verification_id ~authority =
  Outbox.standing config ~task_id ~verification_id ~producer ~reason ~authority

let pending config = ok (Outbox.pending config)
let approvals config = ok (Workspace_task_approval_outbox.pending config)
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
    (match pending config with
     | [ rejection ] ->
       Alcotest.(check string) "typed rejection retains verification correlation"
         verification_id rejection.D.verification_id;
       Alcotest.(check string) "typed rejection retains its reason" reason rejection.reason;
       Alcotest.(check bool) "typed rejection retains its authority" true
         (rejection.authority = system)
     | _ -> Alcotest.fail "rejection must have one durable typed obligation");
    reconcile config ~delivered:0 ~unroutable:1 ~retained:0;
    check_pending config 0;
    Alcotest.(check int) "no queue is written under a name no Keeper reads" 0
      (List.length (queue config));
    (match only_task config with
     | { task_status = D.Todo; handoff_context = Some handoff; _ } ->
       Alcotest.(check (option string)) "the verdict's reason stays on the Task"
         (Some reason) handoff.reason;
       Alcotest.(check (list string)) "verification correlation is not submitted evidence"
         [] handoff.evidence_refs;
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
    let events = Dated_jsonl.Store.at
      (Dated_jsonl.Store.root_of_base_path ~base_path:config.W.base_path)
      Dated_jsonl.Store.Root.Events |> Dated_jsonl.open_store in
    let event = match Dated_jsonl.find_latest_entry_result events (function
      | Dated_jsonl.Parsed (`Assoc _ as json) ->
        let open Yojson.Safe.Util in
        if member "type" json = `String "task_completion_verdict"
           && member "verification_id" json = `String verification_id
        then Some json else None
      | Dated_jsonl.Parsed _ -> None
      | Dated_jsonl.Malformed_json {detail; _} -> Alcotest.fail detail) with
      | Ok (Some event) -> event
      | Ok None -> Alcotest.fail "unroutable release lost its verdict audit"
      | Error error -> Alcotest.fail (Dated_jsonl.read_error_to_string error) in
    let open Yojson.Safe.Util in
    List.iter (fun (field, expected) ->
      Alcotest.(check string) ("durable verdict audit retains " ^ field)
        expected (event |> member field |> to_string))
      [ "task_id", task_id; "verification_id", verification_id; "reason", reason
      ; "verdict", "rejected"; "authority_kind", "system_llm_agent"
      ; "authority_actor", "repair-verifier-run" ];
    reconcile config ~delivered:0 ~retained:0)

(* An exact rejection relation for an impossible Task state is corrupt
   authority, rather than permission to release a newly claimed Task. *)
let test_a_claimed_task_conflict_preserves_the_obligation () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-claimed" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected {reason});
    let backlog = ok (Workspace_backlog.read_backlog_r config) in
    let tasks = List.map (fun (task:D.task) -> {task with task_status=
      D.Claimed {assignee=producer;claimed_at="2026-09-09T00:00:00Z"}}) backlog.tasks in
    W.write_backlog config {backlog with tasks};
    let before = only_task config in
    reconcile config ~delivered:0 ~unroutable:0 ~retained:1;
    check_pending config 1;
    Alcotest.(check string) "conflicting claimed Task is untouched" (D.show_task before)
      (D.show_task (only_task config));
    Alcotest.(check int) "no delivery from conflicting authority" 0 (List.length (queue config)))

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
    reconcile config ~delivered:0 ~unroutable:0 ~retained:1;
    check_pending config 1;
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
    | Ok (W.Released _ | W.Producer_route_unread _
        | W.Rejection_superseded) ->
      Alcotest.fail "a routable producer must not have its task released"
    | Error error -> Alcotest.fail (D.masc_error_to_string error))

(* A route that cannot be read under the lock is its own outcome, carrying the
   read's detail, and not a backlog error: the backlog is fine, and the
   producer may be a Keeper whose meta this binary does not decode. *)
let test_an_unread_route_under_the_lock_is_its_own_outcome () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-then-unread" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    let before = only_task config in
    let route_detail = "the producer's meta does not decode" in
    match
      W.release_unroutable_rejected_task_r config ~authority:system ~task_id
        ~producer ~verification_id ~reason
        ~still_unroutable:(fun () -> Error route_detail)
        ()
    with
    | Ok (W.Producer_route_unread { detail }) ->
      Alcotest.(check string) "the read's own detail" route_detail detail;
      Alcotest.(check string) "the task is left untouched"
        (D.show_task before) (D.show_task (only_task config));
      check_pending config 1
    | Ok (W.Released _ | W.Producer_became_routable
        | W.Rejection_superseded) ->
      Alcotest.fail "an unread route must not release or pass as routable"
    | Error error ->
      Alcotest.failf "an unread route was reported as a backlog error: %s"
        (D.masc_error_to_string error))

(* The same window with a meta this binary does not decode, through the real
   route read. The first routing read found nothing, so delivery goes to the
   release; the meta that lands before the lock may be a Keeper, so the task
   stays and the release answers [Error], the arm [reconcile_pending] counts
   as retained. *)
let test_an_undecodable_meta_that_appears_before_the_lock_keeps_the_task () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-then-undecodable" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    let item =
      match pending config with
      | [ item ] -> item
      | items -> Alcotest.failf "one obligation, found %d" (List.length items)
    in
    (match
       Wake.wake_rejected_producer ~config ~producer ~task_id ~verification_id
         ~reason ~authority:system
     with
     | Wake.Unroutable_producer _ -> ()
     | Wake.Rejection_superseded _ -> Alcotest.fail "current rejection was superseded"
     | Wake.Signaled _ | Wake.Durable_deferred _ | Wake.Durable_wake_failed _
     | Wake.Producer_identity_lookup_failed _ | Wake.Durable_queue_failed _ ->
       Alcotest.fail "the first routing read must find no Keeper");
    let meta_path = Masc.Keeper_types_profile.keeper_meta_path config producer in
    Fs_compat.mkdir_p (Filename.dirname meta_path);
    Out_channel.with_open_text meta_path (fun out -> output_string out "[]");
    let before = only_task config in
    (match Wake.release_unroutable_task ~config item with
     | Error _ -> ()
     | Ok (`Superseded | `Release_refused | `Released _) ->
       Alcotest.fail "a producer whose meta cannot be read must keep its task");
    Alcotest.(check string) "the task is left where the delivery expects it"
      (D.show_task before) (D.show_task (only_task config));
    check_pending config 1;
    Alcotest.(check string) "the meta is left as it landed" "[]"
      (In_channel.with_open_text meta_path In_channel.input_all);
    (* The next interval reads the same meta first and keeps the obligation. *)
    reconcile config ~delivered:0 ~unroutable:0 ~retained:1;
    check_pending config 1)

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
    ignore (submit_repair config);
    let before = only_task config in
    reconcile config ~delivered:0 ~unroutable:0 ~retained:0;
    check_pending config 0;
    Alcotest.(check string) "the newer submission is left exactly as it stands"
      (D.show_task before) (D.show_task (only_task config)))

(* A vanished Task with a still-current relation is inconsistent authority.
   Do not turn a failed authoritative join into successful delivery. *)
let test_missing_task_preserves_the_conflicting_obligation () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-deleted-task" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected { reason });
    set_tasks config [];
    reconcile config ~delivered:0 ~unroutable:0 ~retained:1;
    check_pending config 1;
    Alcotest.(check int) "missing Task cannot create a queue row" 0 (List.length (queue config)))

(* Release retires its relation in the same Task commit. Replaying a held
   pre-release snapshot after that commit cannot recreate a delivery receipt. *)
let test_release_before_acknowledgement_replays_idempotently () =
  with_workspace (fun config ->
    let verification_id = "vrf-no-keeper-replay" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected {reason});
    let obligation = match pending config with
      | [item] -> item | items -> Alcotest.failf "one obligation, found %d" (List.length items) in
    (match Wake.release_unroutable_task ~config obligation with
     | Ok (`Released _) -> ()
     | Ok (`Superseded | `Release_refused) ->
       Alcotest.fail "current unroutable rejection was not released"
     | Error detail -> Alcotest.fail detail);
    let released = only_task config in
    (match released.handoff_context with
     | Some handoff ->
       Alcotest.(check (list string))
         "unroutable rejection does not turn its verification ID into evidence"
         [] handoff.evidence_refs;
       Alcotest.(check (option string)) "release retains the correction reason"
         (Some reason) handoff.reason
     | None -> Alcotest.fail "unroutable release must retain the correction handoff");
    check_pending config 0;
    (match Wake.release_unroutable_task ~config obligation with
     | Ok `Superseded -> ()
     | Ok (`Released _ | `Release_refused) ->
       Alcotest.fail "released snapshot retained authority"
     | Error detail -> Alcotest.fail detail);
    ok (Outbox.acknowledge config ~task_id ~verification_id);
    check_pending config 0;
    Alcotest.(check int) "stale release ACK cannot create a receipt" 0
      (List.length (ok (Workspace_backlog.read_backlog_r config)).delivered_completion_rejections);
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
     | Wake.Rejection_superseded _ -> Alcotest.fail "current rejection was superseded"
     | Wake.Unroutable_producer _ | Wake.Producer_identity_lookup_failed _
     | Wake.Durable_queue_failed _ ->
       Alcotest.fail "fixture failed to durably enqueue rejection");
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
    Alcotest.(check int) "approval committed a delivery obligation" 1
      (List.length (approvals config));
    reconcile config ~delivered:1 ~retained:0;
    Alcotest.(check int) "approval delivery acknowledged" 0 (List.length (approvals config));
    Alcotest.(check int) "approval has no rejection stimulus" 0
      (List.length
         (List.filter
            (fun stimulus ->
               match stimulus.Keeper_event_queue.payload with
               | Keeper_event_queue.Task_outcome _ -> false
               | _ -> true)
            (queue config)));
    (* The approval still reaches the producer in its own right: the twin wake
       carries the typed outcome, with no rejection/repair obligation. *)
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

let check_approved config ~verification_ids ~authority =
  let identities = List.map (fun stimulus ->
    match stimulus.Keeper_event_queue.payload with
    | Keeper_event_queue.Task_outcome outcome ->
      Alcotest.(check string) "approval task" task_id outcome.to_task_id;
      Alcotest.(check string) "approval producer" producer outcome.to_producer;
      Alcotest.(check bool) "approval authority" true (authority = outcome.to_authority);
      outcome.to_verification_id
    | _ -> Alcotest.fail "approval delivered a non-outcome stimulus") (queue config) in
  Alcotest.(check (list string)) "exact approved verification identities"
    (List.sort String.compare verification_ids) (List.sort String.compare identities)

let check_done config =
  match (only_task config).task_status with
  | D.Done _ -> ()
  | _ -> Alcotest.fail "approval delivery must leave the Task completed"

let test_approval_projection_failure_recovers_after_restart () =
  with_workspace (fun config ->
    persist_producer config;
    let verification_id = "vrf-approved-projection-failed" in
    prepare_submission config verification_id;
    let saved = Atomic.get Workspace_hooks.verification_notify_verdict_fn in
    Fun.protect ~finally:(fun () -> Atomic.set Workspace_hooks.verification_notify_verdict_fn saved)
      (fun () ->
        Atomic.set Workspace_hooks.verification_notify_verdict_fn
          (fun _ ~task_id:_ ~producer:_ ~authority:_ ~verification_id:_ ~decision:_ ->
            failwith "fixture: Board/SSE projection unavailable");
        commit config ~authority:human ~verification_id D.Verdict_approved);
    let recovered = W.default_config config.W.base_path in
    check_done recovered;
    Alcotest.(check int) "no notification hook was needed" 0 (List.length (queue recovered));
    Alcotest.(check int) "fresh read owns approval delivery" 1 (List.length (approvals recovered));
    reconcile recovered ~delivered:1 ~retained:0;
    check_done recovered;
    check_approved recovered ~verification_ids:[verification_id] ~authority:human;
    reconcile recovered ~delivered:0 ~retained:0)

let test_approval_queue_failure_retains_obligation () =
  with_workspace (fun config ->
    persist_producer config;
    let verification_id = "vrf-approved-queue-failed" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id D.Verdict_approved;
    let path = snapshot_path config in
    Fs_compat.mkdir_p (Filename.dirname path);
    Out_channel.with_open_text path (fun out -> output_string out "{corrupt queue");
    reconcile config ~delivered:0 ~retained:1;
    Alcotest.(check int) "failed enqueue retains approval" 1 (List.length (approvals config));
    check_done config;
    Sys.remove path;
    reconcile (W.default_config config.W.base_path) ~delivered:1 ~retained:0;
    check_approved config ~verification_ids:[verification_id] ~authority:system;
    Alcotest.(check int) "recovered approval acknowledged" 0 (List.length (approvals config)))

let test_approval_enqueue_before_ack_is_idempotent () =
  with_workspace (fun config ->
    persist_producer config;
    let verification_id = "vrf-approved-before-ack" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id D.Verdict_approved;
    (match Masc.Keeper_task_outcome_wake.wake_approved_producer
             ~config ~producer ~task_id ~verification_id ~authority:system with
     | Signaled _ | Durable_deferred _ | Durable_wake_failed _ -> ()
     | _ -> Alcotest.fail "fixture could not enqueue approval");
    (* The persisted source remains after the queue write: replay the same
       crash window in a fresh configuration, without a second model verdict. *)
    Alcotest.(check int) "source not yet acknowledged" 1 (List.length (approvals config));
    ok (Workspace_task_approval_outbox.acknowledge config ~task_id ~verification_id:"vrf-stale");
    Alcotest.(check int) "stale acknowledgement cannot lose current approval" 1
      (List.length (approvals config));
    reconcile (W.default_config config.W.base_path) ~delivered:1 ~retained:0;
    check_approved config ~verification_ids:[verification_id] ~authority:system;
    check_done config;
    reconcile config ~delivered:0 ~retained:0)

let test_unroutable_approval_stays_completed () =
  with_workspace (fun config ->
    let verification_id = "vrf-approved-no-keeper" in
    prepare_submission config verification_id;
    commit config ~authority:human ~verification_id D.Verdict_approved;
    reconcile config ~delivered:0 ~unroutable:1 ~retained:0;
    check_done config;
    Alcotest.(check int) "unroutable terminal outcome acknowledged" 0 (List.length (approvals config)))

let test_approval_codec_fails_closed () =
  with_workspace (fun config ->
    prepare_submission config "vrf-approved-codec";
    commit config ~authority:system ~verification_id:"vrf-approved-codec" D.Verdict_approved;
    let fields = W.read_backlog config |> D.backlog_to_yojson |> Yojson.Safe.Util.to_assoc in
    let entries = List.assoc "pending_completion_approvals" fields in
    let row = match entries with `List [row] -> row | _ -> Alcotest.fail "missing approval" in
    let row_fields = Yojson.Safe.Util.to_assoc row in
    let corrupt values = `Assoc (("pending_completion_approvals", values)
      :: List.remove_assoc "pending_completion_approvals" fields) in
    List.iter (fun json ->
      Alcotest.(check bool) "malformed approval obligation is never silently dropped" true
        (Result.is_error (D.backlog_of_yojson json)))
      [ corrupt (`String "invalid")
      ; corrupt (`List [row; row])
      ; corrupt (`List [`Assoc (("unexpected", `Bool true) :: row_fields)])
      ; corrupt (`List [`Assoc (("producer", `String "") :: List.remove_assoc "producer" row_fields)])
      ; `Assoc (("pending_completion_approvals", entries) :: fields) ])

let test_resubmit_supersedes_and_stale_ack_preserves_new_rejection () =
  with_workspace (fun config ->
    persist_producer config;
    let old_id = "vrf-old-rejection" in
    prepare_submission config old_id;
    commit config ~authority:system ~verification_id:old_id
      (D.Verdict_rejected { reason });
    check_pending config 1;
    let new_id = submit_repair config in
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

let expect_superseded ~verification_id = function
  | Wake.Rejection_superseded {task_id=actual_task;verification_id=actual_verification} ->
    Alcotest.(check string) "superseded task" task_id actual_task;
    Alcotest.(check string) "superseded verification" verification_id actual_verification
  | Wake.Signaled _ | Wake.Durable_deferred _ | Wake.Durable_wake_failed _
  | Wake.Unroutable_producer _ | Wake.Producer_identity_lookup_failed _
  | Wake.Durable_queue_failed _ -> Alcotest.fail "old rejection still owned delivery"

let test_snapshot_before_resubmit_cannot_enqueue () =
  with_workspace (fun config ->
    persist_producer config;
    let old_id = "vrf-snapshot-before-resubmit" in
    prepare_submission config old_id;
    commit config ~authority:system ~verification_id:old_id (D.Verdict_rejected {reason});
    let snapshot = match pending config with
      | [item] -> item | _ -> Alcotest.fail "missing original pending rejection" in
    let new_id = submit_repair config in
    expect_superseded ~verification_id:old_id
      (Wake.wake_rejected_producer ~config ~producer:snapshot.producer
        ~task_id:snapshot.task_id ~verification_id:snapshot.verification_id
        ~reason:snapshot.reason ~authority:snapshot.authority);
    Alcotest.(check int) "old snapshot cannot create a queue row" 0 (List.length (queue config));
    check_pending config 0;
    match (only_task config).task_status with
    | D.AwaitingVerification {verification_id;_} ->
      Alcotest.(check string) "new submission keeps authority" new_id verification_id
    | D.Todo | D.Claimed _ | D.InProgress _ | D.Done _ | D.Cancelled _ ->
      Alcotest.fail "old wake changed the newer submission")

let test_delivered_receipt_remains_current_until_resubmit () =
  with_workspace (fun config ->
    persist_producer config;
    let old_id = "vrf-delivered-before-resubmit" in
    prepare_submission config old_id;
    commit config ~authority:system ~verification_id:old_id (D.Verdict_rejected {reason});
    reconcile config ~delivered:1 ~retained:0;
    check_pending config 0;
    Alcotest.(check bool) "ACK retains current rejection authority" true
      (ok (standing config ~verification_id:old_id ~authority:system) = Outbox.Current);
    let backlog = ok (Workspace_backlog.read_backlog_r config) in
    (match backlog.delivered_completion_rejections with
     | [receipt] ->
       Alcotest.(check string) "exact delivered receipt" old_id receipt.D.verification_id
     | _ -> Alcotest.fail "ACK did not preserve the delivered relation");
    expect_superseded ~verification_id:old_id
      (Wake.wake_rejected_producer ~config ~producer ~task_id ~verification_id:old_id
        ~reason ~authority:system);
    check_rejection config ~verification_id:old_id ~authority:system;
    let new_id = submit_repair config in
    Alcotest.(check bool) "resubmission retires delivered authority" true
      (ok (standing config ~verification_id:old_id ~authority:system) = Outbox.Obsolete);
    let backlog = ok (Workspace_backlog.read_backlog_r config) in
    Alcotest.(check int) "resubmission retires old receipt" 0
      (List.length backlog.delivered_completion_rejections);
    commit config ~authority:human ~verification_id:new_id (D.Verdict_rejected {reason});
    ok (Outbox.acknowledge config ~task_id ~verification_id:old_id);
    check_pending config 1;
    Alcotest.(check int) "stale ACK cannot install an old receipt" 0
      (List.length (ok (Workspace_backlog.read_backlog_r config)).delivered_completion_rejections);
    check_rejection config ~verification_id:old_id ~authority:system)

let test_old_unroutable_snapshot_cannot_release_new_rejection () =
  with_workspace (fun config ->
    let old_id = "vrf-release-snapshot" in
    prepare_submission config old_id;
    commit config ~authority:system ~verification_id:old_id (D.Verdict_rejected {reason});
    let snapshot = match pending config with
      | [item] -> item | _ -> Alcotest.fail "missing original pending rejection" in
    let new_id = submit_repair config in
    commit config ~authority:human ~verification_id:new_id (D.Verdict_rejected {reason});
    let before = only_task config in
    (match Wake.release_unroutable_task ~config snapshot with
     | Ok `Superseded -> ()
     | Ok (`Released _ | `Release_refused) ->
       Alcotest.fail "old rejection snapshot retained release authority"
     | Error detail -> Alcotest.fail detail);
    (match W.release_unroutable_rejected_task_r config ~authority:system ~task_id
       ~producer ~verification_id:old_id ~reason
       ~still_unroutable:(fun () -> Alcotest.fail "old identity reached route/effect check") () with
     | Ok W.Rejection_superseded -> ()
     | Ok (W.Released _ | W.Producer_became_routable
         | W.Producer_route_unread _) ->
       Alcotest.fail "old direct release did not report supersession"
     | Error error -> Alcotest.fail (D.masc_error_to_string error));
    Alcotest.(check string) "new rejected work remains held" (D.show_task before)
      (D.show_task (only_task config));
    match pending config with
    | [item] ->
      Alcotest.(check string) "new pending rejection survives old release" new_id
        item.D.verification_id;
      Alcotest.(check bool) "new rejection authority survives" true (item.authority=human)
    | _ -> Alcotest.fail "old release changed the newer pending rejection")

let test_corrupt_primary_blocks_wake_without_changing_queue () =
  with_workspace (fun config ->
    persist_producer config;
    let verification_id = "vrf-corrupt-primary-before-ack" in
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id (D.Verdict_rejected {reason});
    (match Wake.wake_rejected_producer ~config ~producer ~task_id ~verification_id
       ~reason ~authority:system with
     | Wake.Signaled _ | Wake.Durable_deferred _ | Wake.Durable_wake_failed _ -> ()
     | Wake.Rejection_superseded _ | Wake.Unroutable_producer _
     | Wake.Producer_identity_lookup_failed _ | Wake.Durable_queue_failed _ ->
       Alcotest.fail "fixture did not enqueue the current rejection");
    check_pending config 1;
    let queue_path = snapshot_path config in
    let before_queue = In_channel.with_open_text queue_path In_channel.input_all in
    let backlog_path = Workspace_backlog.backlog_path config in
    let before_backlog = In_channel.with_open_text backlog_path In_channel.input_all in
    let corrupt = "{corrupt authoritative backlog" in
    Out_channel.with_open_text backlog_path (fun out -> output_string out corrupt);
    (match Wake.wake_rejected_producer ~config ~producer ~task_id ~verification_id
       ~reason ~authority:system with
     | Wake.Durable_queue_failed _ -> ()
     | Wake.Signaled _ | Wake.Durable_deferred _ | Wake.Durable_wake_failed _
     | Wake.Rejection_superseded _ | Wake.Unroutable_producer _
     | Wake.Producer_identity_lookup_failed _ ->
       Alcotest.fail "wake accepted a recovered or corrupt primary backlog");
    Alcotest.(check bool) "standing never trusts recovered primary" true
      (Result.is_error (standing config ~verification_id ~authority:system));
    Alcotest.(check string) "queue unchanged across failed authority read" before_queue
      (In_channel.with_open_text queue_path In_channel.input_all);
    Alcotest.(check string) "corrupt primary preserved" corrupt
      (In_channel.with_open_text backlog_path In_channel.input_all);
    Out_channel.with_open_text backlog_path (fun out -> output_string out before_backlog);
    check_pending config 1;
    reconcile config ~delivered:1 ~retained:0;
    check_rejection config ~verification_id ~authority:system)

let test_backlog_without_delivered_observations_lists_and_claims () =
  with_workspace (fun config ->
    let path = Workspace_backlog.backlog_path config in
    let fields = Yojson.Safe.from_file path |> Yojson.Safe.Util.to_assoc in
    let document = `Assoc (List.remove_assoc "delivered_completion_rejections" fields) in
    Yojson.Safe.to_file path document;
    let loaded = ok (Workspace_backlog.read_backlog_r config) in
    Alcotest.(check int) "Task inventory remains readable" 1 (List.length loaded.tasks);
    Alcotest.(check int) "absent relation supplies no delivered observation" 0
      (List.length loaded.delivered_completion_rejections);
    Alcotest.(check bool) "Task list still contains the actual Task" true
      (Astring.String.is_infix ~affix:task_id (W.list_tasks config));
    ignore (workspace_ok (W.claim_task_r config ~agent_name:producer ~task_id ()));
    match only_task config with
    | {task_status=D.Claimed {assignee; _}; _} ->
      Alcotest.(check string) "claim commits under the same available backlog" producer assignee
    | _ -> Alcotest.fail "the readable unclaimed Task must remain claimable")

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

let test_daemon_delivery ?(approve=false) ~start_before_commit () =
  with_workspace_runtime (fun ~sw ~clock config ->
    persist_producer config;
    let verification_id = "vrf-native-daemon-repair" in
    let verdict = if approve then D.Verdict_approved else D.Verdict_rejected { reason } in
    let check_delivered = if approve then check_approved else check_rejections in
    let reviewer_calls = ref 0 in
    let previous_reviewer =
      Atomic.get Masc.Task.Anti_rationalization.run_llm_reviewer_fn in
    Eio.Switch.on_release sw (fun () ->
      Atomic.set Masc.Task.Anti_rationalization.run_llm_reviewer_fn previous_reviewer);
    Atomic.set Masc.Task.Anti_rationalization.run_llm_reviewer_fn
      (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_ ?system_prompt:_ ?goal_blocks:_
          ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
          ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
        incr reviewer_calls;
        Alcotest.fail "delivery recovery must not invoke a model");
    (* Poll only the durable result, never manually reconcile. The bound belongs
       to this test's failure detection, not the product's recovery policy. *)
    let await_delivery expected_count =
      Eio.Time.with_timeout_exn clock 5.0 (fun () ->
        let rec await () =
          if pending config = [] && approvals config = [] && List.length (queue config) = expected_count then ()
          else (Eio.Time.sleep clock 0.01; await ())
        in
        await ())
    in
    let boot_id = "vrf-native-daemon-boot-sentinel" in
    if start_before_commit then (
      prepare_submission config boot_id;
      commit config ~authority:system ~verification_id:boot_id (D.Verdict_rejected { reason });
      Masc.Completion_authority_agent.start ~sw ~clock ~config;
      await_delivery 1;
      check_rejection config ~verification_id:boot_id ~authority:system;
      (* The daemon scans boot review scopes before delivering this sentinel.
         Its queue row and acknowledged outbox prove that startup recovery has
         finished before the second commit. Only a fresh hook wake can now
         deliver the second verdict. Leave the first row intact and verify
         both exact identities, so no test-side queue mutation drives delivery. *)
      check_pending config 0);
    prepare_submission config verification_id;
    commit config ~authority:system ~verification_id verdict;
    if not start_before_commit then
      Masc.Completion_authority_agent.start ~sw ~clock ~config;
    let verification_ids =
      if start_before_commit then [boot_id; verification_id] else [verification_id] in
    await_delivery (List.length verification_ids);
    if approve && start_before_commit then (
      (* The sentinel is a rejection: the fixture may resubmit rejected work,
         but must not approve a completed Task twice (outcome ids are task-keyed). *)
      let actual = List.map (fun stimulus ->
        match stimulus.Keeper_event_queue.payload with
        | Keeper_event_queue.Completion_authority_rejected rejection ->
          "rejected", rejection.car_verification_id
        | Keeper_event_queue.Task_outcome outcome -> "approved", outcome.to_verification_id
        | _ -> Alcotest.fail "unexpected daemon stimulus") (queue config) in
      Alcotest.(check (list (pair string string))) "boot sentinel and committed approval"
        (List.sort Stdlib.compare ["rejected", boot_id; "approved", verification_id])
        (List.sort Stdlib.compare actual))
    else check_delivered config ~verification_ids ~authority:system;
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
      ; Alcotest.test_case "a conflicting claimed task preserves the obligation"
          `Quick test_a_claimed_task_conflict_preserves_the_obligation
      ; Alcotest.test_case "an operator verdict releases as the operator"
          `Quick test_an_operator_verdict_releases_as_the_operator
      ; Alcotest.test_case "a queue that appears before the lock keeps the task"
          `Quick test_a_queue_that_appears_before_the_lock_keeps_the_task
      ; Alcotest.test_case "an unread route under the lock is its own outcome"
          `Quick test_an_unread_route_under_the_lock_is_its_own_outcome
      ; Alcotest.test_case "an undecodable meta before the lock keeps the task"
          `Quick test_an_undecodable_meta_that_appears_before_the_lock_keeps_the_task
      ; Alcotest.test_case "a failed release keeps the obligation"
          `Quick test_a_failed_release_keeps_the_obligation
      ; Alcotest.test_case "a release that can never succeed ends the obligation"
          `Quick test_a_release_that_can_never_succeed_ends_the_obligation
      ; Alcotest.test_case "a missing task preserves the conflicting obligation"
          `Quick test_missing_task_preserves_the_conflicting_obligation
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
      ; Alcotest.test_case "approval boot recovery" `Quick
          (test_daemon_delivery ~approve:true ~start_before_commit:false)
      ; Alcotest.test_case "approval live commit wake" `Quick
          (test_daemon_delivery ~approve:true ~start_before_commit:true)
      ; Alcotest.test_case "approval survives projection failure and restart" `Quick test_approval_projection_failure_recovers_after_restart
      ; Alcotest.test_case "approval queue failure retains delivery" `Quick test_approval_queue_failure_retains_obligation
      ; Alcotest.test_case "approval enqueue before ack deduplicates" `Quick test_approval_enqueue_before_ack_is_idempotent
      ; Alcotest.test_case "unroutable approval remains Done" `Quick test_unroutable_approval_stays_completed
      ; Alcotest.test_case "approval codec fails closed" `Quick test_approval_codec_fails_closed
      ; Alcotest.test_case "approval creates no repair" `Quick test_approval_has_no_repair_obligation
      ; Alcotest.test_case "resubmission and stale acknowledgement" `Quick test_resubmit_supersedes_and_stale_ack_preserves_new_rejection
      ; Alcotest.test_case "old snapshot cannot enqueue after resubmission" `Quick test_snapshot_before_resubmit_cannot_enqueue
      ; Alcotest.test_case "delivered authority retires only on resubmission" `Quick test_delivered_receipt_remains_current_until_resubmit
      ; Alcotest.test_case "old release cannot retire a newer rejection" `Quick test_old_unroutable_snapshot_cannot_release_new_rejection
      ; Alcotest.test_case "corrupt primary preserves queue and pending rejection" `Quick test_corrupt_primary_blocks_wake_without_changing_queue
      ; Alcotest.test_case "absent delivered observations preserve Task list and claim" `Quick test_backlog_without_delivered_observations_lists_and_claims
      ; Alcotest.test_case "corrupt outbox fails closed" `Quick test_corrupt_explicit_outbox_is_not_empty
      ] ]
