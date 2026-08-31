open Alcotest
open Schedule_domain
open Schedule_store

let schedules_path config =
  Filename.concat (Workspace_utils.masc_dir config) "schedules.json"
;;

let json = testable Yojson.Safe.pp Yojson.Safe.equal

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_dir "schedule_store_test" "" in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> Masc_test_deps.cleanup_test_workspace dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  f config
;;

let schedules_recovery_path config = schedules_path config ^ ".last-good"

let human ?display_name id = { id; kind = Human_operator; display_name }

let payload_json () =
  `Assoc
    [ "kind", `String "consumer.note"
    ; "body", `Assoc [ "text", `String "ship later" ]
    ]
;;

let make_request
  ?(schedule_id = "sched-1")
  ?expires_at
  ?recurrence
  ()
  =
  match
    create_request ~schedule_id ~requested_by:(human "requester")
      ~scheduled_by:(human "scheduler") ~requested_at:100.0 ~due_at:200.0
      ?expires_at ~payload:(payload_json ()) ~source:Operator_request ?recurrence ()
  with
  | Ok request -> request
  | Error msg -> fail msg
;;

let insert_ok config request =
  match insert_request config request with
  | Ok stored -> stored
  | Error err -> fail (store_error_to_string err)
;;

let store_ok label = function
  | Ok value -> value
  | Error err -> fail (label ^ ": " ^ store_error_to_string err)
;;

let check_error label expected = function
  | Ok _ -> fail (label ^ ": expected error")
  | Error actual ->
    check string label (store_error_to_string expected) (store_error_to_string actual)
;;

let check_status label expected actual =
  check string label (schedule_status_to_string expected) (schedule_status_to_string actual)
;;

let find_wake_for_occurrence
      state
      ~schedule_instance_id
      ~schedule_id
      ~due_at
      ~payload_digest
  =
  List.find_opt
    (fun (wake : wake_record) ->
       String.equal wake.schedule_instance_id schedule_instance_id
       && String.equal wake.schedule_id schedule_id
       && Float.equal wake.due_at due_at
       && String.equal wake.payload_digest payload_digest)
    state.wakes
;;

let test_insert_persists_and_bumps_version () =
  with_workspace
  @@ fun config ->
  let before = read_state config in
  let req = make_request () in
  (match insert_request config req with
   | Ok _ -> ()
   | Error err -> fail (store_error_to_string err));
  let after = read_state config in
  check int "version bumped" (before.version + 1) after.version;
  check int "one schedule" 1 (List.length after.schedules);
  check_status "stored scheduled" Scheduled (List.hd after.schedules).status
;;

let test_duplicate_insert_rejected_without_bump () =
  with_workspace
  @@ fun config ->
  let req = make_request () in
  ignore (insert_ok config req);
  let before = read_state config in
  check_error "duplicate" Schedule_already_exists (insert_request config req);
  let after = read_state config in
  check int "version unchanged" before.version after.version
;;

let test_update_replaces_active_definition_with_fresh_instance () =
  with_workspace
  @@ fun config ->
  let original = make_request ~schedule_id:"modify-1" () in
  ignore (insert_ok config original);
  let replacement =
    { (make_request ~schedule_id:original.schedule_id ()) with due_at = 350.0 }
  in
  let before = read_state config in
  let updated = store_ok "update" (update_request config replacement) in
  let after = read_state config in
  check string "stable public id" original.schedule_id updated.schedule_id;
  check bool "fresh instance" false
    (String.equal original.schedule_instance_id updated.schedule_instance_id);
  check (float 0.0) "new due time" 350.0 updated.due_at;
  check_status "replacement starts scheduled" Scheduled updated.status;
  check int "one atomic version bump" (before.version + 1) after.version;
  check int "still one schedule" 1 (List.length after.schedules)
;;

let test_update_accepts_due_but_refuses_terminal_definition () =
  with_workspace
  @@ fun config ->
  let due = make_request ~schedule_id:"modify-due" () in
  ignore (insert_ok config due);
  ignore (store_ok "refresh due" (refresh_due config ~now:201.0));
  let replacement = make_request ~schedule_id:due.schedule_id () in
  ignore (store_ok "replace due" (update_request config replacement));
  ignore (store_ok "cancel replacement" (cancel_request config ~schedule_id:due.schedule_id));
  let before = read_state config in
  check_error "terminal update"
    (Invalid_status_transition "only scheduled or due requests can be modified")
    (update_request config (make_request ~schedule_id:due.schedule_id ()));
  check int "refusal does not bump" before.version (read_state config).version
;;

let test_update_requires_an_existing_schedule () =
  with_workspace
  @@ fun config ->
  check_error "missing update" Schedule_not_found
    (update_request config (make_request ~schedule_id:"missing" ()))
;;

let test_store_rejects_non_scheduled_initial_status () =
  with_workspace
  @@ fun config ->
  let req = { (make_request ()) with status = Due } in
  match insert_request config req with
  | Ok _ -> fail "expected invalid initial status"
  | Error (Invalid_initial_status _) -> ()
  | Error err -> fail (store_error_to_string err)
;;

let test_cancel_request_marks_cancelled () =
  with_workspace
  @@ fun config ->
  let req = make_request ~schedule_id:"cancel-1" () in
  ignore (insert_ok config req);
  (match cancel_request config ~schedule_id:req.schedule_id with
   | Ok updated -> check_status "cancelled status" Cancelled updated.status
   | Error err -> fail (store_error_to_string err));
  match get_schedule config ~schedule_id:req.schedule_id with
  | Some stored -> check_status "stored cancelled" Cancelled stored.status
  | None -> fail "schedule missing"
;;

let test_due_candidates_dispatch_without_scheduler_authorization_state () =
  with_workspace
  @@ fun config ->
  let req = make_request () in
  ignore (insert_ok config req);
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "scheduled became due" 1 changed
   | Error err -> fail (store_error_to_string err));
  let candidates = due_wake_candidates (read_state config) in
  check int "one due candidate" 1 (List.length candidates)
;;

let test_due_candidate_starts_without_authorization_state () =
  with_workspace
  @@ fun config ->
  let req = make_request ~schedule_id:"due-1" () in
  ignore (insert_ok config req);
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "request due" 1 changed
   | Error err -> fail (store_error_to_string err));
  check int "due candidate" 1
    (List.length (due_wake_candidates (read_state config)))
;;

let test_refresh_due_expires_scheduled_and_due () =
  with_workspace
  @@ fun config ->
  let scheduled =
    make_request ~schedule_id:"expire-scheduled" ~expires_at:150.0 ()
  in
  let due =
    make_request ~schedule_id:"expire-due" ~expires_at:250.0 ()
  in
  ignore (insert_ok config scheduled);
  ignore (insert_ok config due);
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "scheduled expired and due marked" 2 changed
   | Error err -> fail (store_error_to_string err));
  (match refresh_due config ~now:251.0 with
   | Ok (_, changed) -> check int "due expired" 1 changed
   | Error err -> fail (store_error_to_string err));
  (match
     get_schedule config ~schedule_id:"expire-scheduled",
     get_schedule config ~schedule_id:"expire-due"
   with
   | Some scheduled, Some due ->
     check_status "scheduled expired" Expired scheduled.status;
     check_status "due expired" Expired due.status;
     check int "expired schedules are not due candidates" 0
       (List.length (due_wake_candidates (read_state config)))
   | _ -> fail "expired schedules missing")
;;

let test_reschedule_due_recurring_advances_only_matching_recurring_rows () =
  with_workspace
  @@ fun config ->
  let recurring =
    make_request ~schedule_id:"loop-1"
      ~recurrence:(Interval { interval_sec = 60 })
      ()
  in
  let one_shot = make_request ~schedule_id:"once-1" () in
  ignore (insert_ok config recurring);
  ignore (insert_ok config one_shot);
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "both due" 2 changed
   | Error err -> fail (store_error_to_string err));
  (match
     reschedule_due_recurring config ~now:201.0
       ~schedule_ids:[ "loop-1"; "once-1"; "missing" ]
   with
   | Error err -> fail (store_error_to_string err)
   | Ok (_, changed) -> check int "one rescheduled" 1 changed);
  match
    get_schedule config ~schedule_id:"loop-1",
    get_schedule config ~schedule_id:"once-1"
  with
  | Some loop, Some once ->
    check_status "loop scheduled" Scheduled loop.status;
    check (float 0.001) "loop next due" 260.0 loop.due_at;
    check_status "one-shot left due" Due once.status
  | _ -> fail "schedules missing"
;;

let test_reschedule_due_cron_advances_to_next_match () =
  with_workspace
  @@ fun config ->
  let cron =
    make_request ~schedule_id:"cron-1"
      ~recurrence:(Cron { expression = "0 9 * * 1-5"; timezone = "UTC" })
      ()
  in
  let cron = { cron with due_at = 32400.0 } in
  ignore (insert_ok config cron);
  (match refresh_due config ~now:32401.0 with
   | Ok (_, changed) -> check int "cron due" 1 changed
   | Error err -> fail (store_error_to_string err));
  (match reschedule_due_recurring config ~now:32401.0 ~schedule_ids:[ "cron-1" ] with
   | Error err -> fail (store_error_to_string err)
   | Ok (_, changed) -> check int "cron rescheduled" 1 changed);
  match get_schedule config ~schedule_id:"cron-1" with
  | Some stored ->
    check_status "cron scheduled" Scheduled stored.status;
    check (float 0.001) "cron next due" 118800.0 stored.due_at
  | None -> fail "cron schedule missing"
;;

let test_recovers_from_last_good () =
  with_workspace
  @@ fun config ->
  let req = make_request () in
  ignore (insert_ok config req);
  Workspace_core.write_text config (schedules_path config) "{not json";
  let recovered = read_state config in
  check int "recovered schedule" 1 (List.length recovered.schedules)
;;

let recovery_path config = schedules_path config ^ ".last-good"

(* Corrupt both the primary and the .last-good recovery file. After [insert_ok],
   [write_state] has produced a parseable .last-good, so we overwrite both files
   with non-JSON to simulate out-of-band corruption (e.g. partial write / schema
   evolution). *)
let corrupt_both config =
  Workspace_core.write_text config (schedules_path config) "{not json";
  Workspace_core.write_text config (recovery_path config) "}also not json"
;;

(* Remove the primary ledger while leaving the .last-good mirror alone, the way an
   out-of-band deletion does (rm, partial rsync, a cleanup script). *)
let delete_primary config =
  Workspace_core.delete_path config (schedules_path config);
  check bool "primary ledger removed" false
    (Workspace_utils.path_exists config (schedules_path config))
;;

let test_startup_recovery_returns_only_running_schedule_to_due () =
  with_workspace
  @@ fun config ->
  let interrupted = make_request ~schedule_id:"interrupted" () in
  let untouched = make_request ~schedule_id:"untouched" () in
  ignore (insert_ok config interrupted);
  ignore (insert_ok config untouched);
  (match refresh_due config ~now:201.0 with
   | Ok _ -> ()
   | Error err -> fail (store_error_to_string err));
  (match start_due_candidate config ~now:202.0 ~schedule_id:interrupted.schedule_id with
   | Ok running -> check_status "interrupted is running" Running running.status
   | Error err -> fail (store_error_to_string err));
  let reason = Interrupted_by_process_restart in
  (match recover_running_on_startup config ~now:203.0 with
   | Ok (_, recovered) -> check int "one interrupted schedule recovered" 1 recovered
   | Error err -> fail (store_error_to_string err));
  (match
     get_schedule config ~schedule_id:interrupted.schedule_id,
     get_schedule config ~schedule_id:untouched.schedule_id
   with
   | Some recovered, Some untouched ->
     check_status "interrupted returned to due" Due recovered.status;
     check_status "other due schedule untouched" Due untouched.status
   | _ -> fail "startup recovery schedules missing");
  (match last_wake_for_schedule_instance (read_state config)
           ~schedule_instance_id:interrupted.schedule_instance_id
           ~schedule_id:interrupted.schedule_id with
   | Some wake ->
     check string "interrupted attempt failed" "failed"
       (wake_status_to_string wake.status);
     check (option string) "typed restart reason serialized"
       (Some (running_recovery_reason_to_string reason))
       wake.error
   | None -> fail "interrupted wake evidence missing");
  let before_repeat = read_state config in
  (match recover_running_on_startup config ~now:204.0 with
   | Ok (_, recovered) -> check int "recovery is idempotent" 0 recovered
   | Error err -> fail (store_error_to_string err));
  check int "idempotent recovery does not rewrite state"
    before_repeat.version
    (read_state config).version
;;

let test_startup_recovery_uses_exact_occurrence_across_clock_rollback () =
  with_workspace
  @@ fun config ->
  let request =
    make_request
      ~schedule_id:"clock-rollback"
      ~recurrence:(Interval { interval_sec = 60 })
      ()
  in
  ignore (insert_ok config request);
  ignore (refresh_due config ~now:201.0);
  ignore (start_due_candidate config ~now:300.0 ~schedule_id:request.schedule_id);
  let advanced =
    match accept_running config ~now:301.0 ~schedule_id:request.schedule_id () with
    | Ok stored -> stored
    | Error err -> fail (store_error_to_string err)
  in
  check_status "older wake was delivered" Scheduled advanced.status;
  ignore (refresh_due config ~now:advanced.due_at);
  let current =
    match start_due_candidate config ~now:100.0 ~schedule_id:request.schedule_id with
    | Ok stored -> stored
    | Error err -> fail (store_error_to_string err)
  in
  check_status "clock-rollback occurrence is running" Running current.status;
  (match recover_running_on_startup config ~now:101.0 with
   | Ok (_, recovered) ->
     check int "exact current occurrence recovered" 1 recovered
   | Error err -> fail (store_error_to_string err));
  let state = read_state config in
  (match get_schedule config ~schedule_id:request.schedule_id with
   | Some stored -> check_status "current occurrence returned to due" Due stored.status
   | None -> fail "clock-rollback schedule missing");
  let digest = payload_digest request.payload in
  (match
     find_wake_for_occurrence
       state
       ~schedule_instance_id:request.schedule_instance_id
       ~schedule_id:request.schedule_id
       ~due_at:advanced.due_at
       ~payload_digest:digest
   with
   | Some wake ->
     check string "newer prepended occurrence failed" "failed"
       (wake_status_to_string wake.status)
   | None -> fail "current clock-rollback wake missing");
  match
    find_wake_for_occurrence
      state
      ~schedule_instance_id:request.schedule_instance_id
      ~schedule_id:request.schedule_id
      ~due_at:request.due_at
      ~payload_digest:digest
  with
  | Some wake ->
    check string "older wake receipt remains succeeded" "succeeded"
      (wake_status_to_string wake.status)
  | None -> fail "older wake receipt missing"
;;

let test_startup_recovery_refuses_corrupt_ledger () =
  with_workspace
  @@ fun config ->
  let request = make_request ~schedule_id:"corrupt-recovery" () in
  ignore (insert_ok config request);
  corrupt_both config;
  let primary_before = Workspace_core.read_text config (schedules_path config) in
  let recovery_before = Workspace_core.read_text config (recovery_path config) in
  (match
     recover_running_on_startup config ~now:203.0
   with
   | Error (Corrupt_ledger _) -> ()
   | Error err -> fail ("expected Corrupt_ledger, got: " ^ store_error_to_string err)
   | Ok _ -> fail "startup recovery silently replaced corrupt ledger");
  check string "corrupt primary preserved" primary_before
    (Workspace_core.read_text config (schedules_path config));
  check string "corrupt recovery preserved" recovery_before
    (Workspace_core.read_text config (recovery_path config))
;;

let test_read_empty_when_file_absent () =
  with_workspace
  @@ fun config ->
  (* A pristine workspace has no schedules.json yet. *)
  let state =
    match read_state_result config with
    | Ok state -> state
    | Error error -> fail (read_error_to_string error)
  in
  check int "fresh store has no schedules" 0 (List.length state.schedules);
  check int "fresh store has no wakes" 0 (List.length state.wakes)
;;

let test_start_and_accept_persist_wake_record () =
  with_workspace
  @@ fun config ->
  let req = make_request ~schedule_id:"exec-1" () in
  ignore (insert_ok config req);
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "became due" 1 changed
   | Error err -> fail (store_error_to_string err));
  (match start_due_candidate config ~now:202.0 ~schedule_id:req.schedule_id with
   | Ok running -> check_status "running" Running running.status
   | Error err -> fail (store_error_to_string err));
  let running_state = read_state config in
  check int "one wake" 1 (List.length running_state.wakes);
  let wake = List.hd running_state.wakes in
  check string "wake status" "running"
    (wake_status_to_string wake.status);
  check string "wake schedule" req.schedule_id wake.schedule_id;
  check (float 0.001) "started at" 202.0 wake.started_at;
  check (float 0.001) "wake due" 200.0 wake.due_at;
  check string "payload digest" (payload_digest req.payload)
    wake.payload_digest;
  (match
     accept_running config ~now:203.0 ~schedule_id:req.schedule_id
       ~detail:(`Assoc [ "kind", `String "test.done" ])
       ()
   with
   | Ok stored -> check_status "succeeded" Succeeded stored.status
   | Error err -> fail (store_error_to_string err));
  let completed_state = read_state config in
  match
    last_wake_for_schedule_instance completed_state
      ~schedule_instance_id:req.schedule_instance_id
      ~schedule_id:req.schedule_id
  with
  | None -> fail "missing completed wake"
  | Some completed ->
    check string "completed status" "succeeded"
      (wake_status_to_string completed.status);
    check (option (float 0.001)) "finished at" (Some 203.0)
      completed.finished_at;
    (match completed.detail with
     | Some (`Assoc fields) ->
       (match List.assoc_opt "kind" fields with
        | Some (`String kind) -> check string "detail kind" "test.done" kind
        | _ -> fail "detail kind missing")
     | _ -> fail "detail missing")
;;

let test_accept_running_completes_wake_receipt () =
  with_workspace
  @@ fun config ->
  let request = make_request ~schedule_id:"accepted-1" () in
  ignore (insert_ok config request);
  (match refresh_due config ~now:201.0 with
   | Ok _ -> ()
   | Error err -> fail (store_error_to_string err));
  (match start_due_candidate config ~now:202.0 ~schedule_id:request.schedule_id with
   | Ok _ -> ()
   | Error err -> fail (store_error_to_string err));
  (match
     accept_running config ~now:203.0 ~schedule_id:request.schedule_id
       ~detail:(`Assoc [ "kind", `String "consumer.accepted" ])
       ()
   with
   | Ok stored -> check_status "one-shot wake completed" Succeeded stored.status
   | Error err -> fail (store_error_to_string err));
  (match
     last_wake_for_schedule_instance
       (read_state config)
       ~schedule_instance_id:request.schedule_instance_id
       ~schedule_id:request.schedule_id
   with
   | None -> fail "accepted wake missing"
   | Some wake ->
     check string "wake delivery succeeded" "succeeded"
       (wake_status_to_string wake.status);
     check (option (float 0.001)) "wake receipt is finished" (Some 203.0)
       wake.finished_at);
  (match recover_running_on_startup config ~now:204.0 with
   | Ok (_, recovered) ->
     check int "accepted work is not redispatched after restart" 0 recovered
   | Error err -> fail (store_error_to_string err))
;;

let test_fail_due_candidate_records_failed_wake () =
  with_workspace
  @@ fun config ->
  let req = make_request ~schedule_id:"unsupported-1" () in
  ignore (insert_ok config req);
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "became due" 1 changed
   | Error err -> fail (store_error_to_string err));
  (match
     fail_due_candidate config ~now:202.0 ~schedule_id:req.schedule_id
       ~error:"unsupported payload"
   with
   | Ok stored -> check_status "failed" Failed stored.status
   | Error err -> fail (store_error_to_string err));
  (match get_schedule config ~schedule_id:req.schedule_id with
   | Some stored -> check_status "stored failed" Failed stored.status
   | None -> fail "schedule missing");
  (match
     last_wake_for_schedule_instance
       (read_state config)
       ~schedule_instance_id:req.schedule_instance_id
       ~schedule_id:req.schedule_id
   with
   | None -> fail "missing failed wake"
   | Some wake ->
     check string "failed wake status" "failed"
       (wake_status_to_string wake.status);
     check (option string) "failed wake error" (Some "unsupported payload")
       wake.error;
     check (option (float 0.001)) "finished at" (Some 202.0)
       wake.finished_at)
;;

(* Terminal wakes are history the runner never reads back, and every mutation
   rewrites the whole store under its lock. Left unbounded they reached 6,534
   records / 5.3 MB against 64 schedules (2026-08-29) and two runner ticks died
   acquiring that lock on 2026-08-28. The bound is per schedule_id: a broken
   schedule out-writes a healthy one by two orders of magnitude, so a global cap
   would be spent on the broken one and erase every other schedule's history. *)
let test_terminal_wakes_are_bounded_per_schedule () =
  with_workspace
  @@ fun config ->
  let run_occurrences ~schedule_id ~count =
    let req =
      make_request ~schedule_id ~recurrence:(Interval { interval_sec = 60 }) ()
    in
    ignore (insert_ok config req);
    let rec turn n now =
      if n <= 0
      then ()
      else (
        (match refresh_due config ~now with
         | Ok _ -> ()
         | Error err -> fail (store_error_to_string err));
        (match start_due_candidate config ~now:(now +. 1.0) ~schedule_id with
         | Ok _ -> ()
         | Error err -> fail (store_error_to_string err));
        (match accept_running config ~now:(now +. 2.0) ~schedule_id () with
         | Ok _ -> ()
         | Error err -> fail (store_error_to_string err));
        turn (n - 1) (now +. 60.0))
    in
    turn count 201.0
  in
  (* Well past the per-schedule bound, so the trim has to engage. *)
  run_occurrences ~schedule_id:"noisy-1" ~count:40;
  (* A quiet schedule whose history must survive the noisy one. *)
  run_occurrences ~schedule_id:"quiet-1" ~count:3;
  let wakes = (read_state config).wakes in
  let for_schedule id =
    List.length
      (List.filter
         (fun (wake : wake_record) -> String.equal wake.schedule_id id)
         wakes)
  in
  check int "noisy schedule is trimmed to the bound" 32 (for_schedule "noisy-1");
  check int "quiet schedule keeps every wake" 3 (for_schedule "quiet-1")
;;

let test_recurring_occurrences_remain_dispatchable () =
  with_workspace
  @@ fun config ->
  let req =
    make_request ~schedule_id:"loop-1"
      ~recurrence:(Interval { interval_sec = 60 })
      ()
  in
  ignore (insert_ok config req);
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "first due" 1 changed
   | Error err -> fail (store_error_to_string err));
  check int "first occurrence candidate" 1
    (List.length (due_wake_candidates (read_state config)));
  (match start_due_candidate config ~now:202.0 ~schedule_id:req.schedule_id with
   | Ok running -> check_status "running first occurrence" Running running.status
   | Error err -> fail (store_error_to_string err));
  (match accept_running config ~now:203.0 ~schedule_id:req.schedule_id () with
   | Ok stored ->
     check_status "rescheduled" Scheduled stored.status;
     check (float 0.001) "next due" 260.0 stored.due_at
   | Error err -> fail (store_error_to_string err));
  (match refresh_due config ~now:260.0 with
   | Ok (_, changed) -> check int "second due" 1 changed
   | Error err -> fail (store_error_to_string err));
  check int "second occurrence candidate" 1
    (List.length (due_wake_candidates (read_state config)))
;;

let test_read_error_when_both_unparseable () =
  with_workspace
  @@ fun config ->
  let req = make_request () in
  ignore (insert_ok config req);
  corrupt_both config;
  match read_state_result config with
  | Error (Corrupt_read_ledger { primary_err; recovery_err }) ->
    check bool "primary error is non-empty" true (String.length primary_err > 0);
    check bool "recovery error reported" true (Option.is_some recovery_err)
  | Ok _ -> fail "corrupt ledger returned a readable state"
;;

let test_read_state_raises_on_corrupt () =
  with_workspace
  @@ fun config ->
  let req = make_request () in
  ignore (insert_ok config req);
  corrupt_both config;
  match read_state config with
  | _ -> fail "read_state silently returned a state for a corrupt ledger"
  | exception Schedule_store.Corrupt_ledger_exn _ -> ()
;;

(* [load] decides over two probes — the primary ledger and its [.last-good]
   mirror — and an absent mirror is the only recovery result whose meaning
   depends on which way the primary failed: an uninitialised store is [Fresh],
   a broken primary with no mirror is [Corrupt].

   [corrupt_both] leaves the mirror present-but-unparseable, so neither of
   these two inputs was covered. Collapsing the primary axis would turn the
   second into an empty state, which is the silent-data-loss shape
   [test_mutation_refused_and_preserves_corrupt_ledger] exists to prevent. *)
let test_absent_mirror_separates_uninitialised_from_corrupt () =
  with_workspace
  @@ fun config ->
  (match Schedule_store.read_state_result config with
   | Ok state ->
     check int "an uninitialised store reads as empty" 0
       (List.length state.Schedule_store.schedules)
   | Error error ->
     failf
       "an uninitialised store must not read as corrupt: %s"
       (Schedule_store.read_error_to_string error));
  let req = make_request () in
  ignore (insert_ok config req);
  Workspace_core.write_text config (schedules_path config) "{not json";
  Workspace_core.delete_path config (recovery_path config);
  check bool "recovery mirror removed" false
    (Workspace_utils.path_exists config (recovery_path config));
  match Schedule_store.read_state_result config with
  | Ok _ -> fail "a broken primary with no mirror must not read as empty"
  | Error (Schedule_store.Corrupt_read_ledger { recovery_err; _ }) ->
    check (option string) "no mirror means no recovery detail" None recovery_err
;;

(* The core silent-failure-to-data-loss regression: a mutation on a corrupt
   ledger must be refused (typed [Corrupt_ledger]) and must NOT overwrite the
   present-but-corrupt files with an empty default. *)
let test_mutation_refused_and_preserves_corrupt_ledger () =
  with_workspace
  @@ fun config ->
  let req = make_request () in
  ignore (insert_ok config req);
  corrupt_both config;
  let primary_before = Workspace_core.read_text config (schedules_path config) in
  let recovery_before = Workspace_core.read_text config (schedules_recovery_path config) in
  (match insert_request config (make_request ~schedule_id:"sched-2" ()) with
   | Ok _ -> fail "insert on corrupt ledger unexpectedly succeeded"
   | Error (Corrupt_ledger _) -> ()
   | Error err -> fail ("expected Corrupt_ledger, got: " ^ store_error_to_string err));
  let primary_after = Workspace_core.read_text config (schedules_path config) in
  let recovery_after = Workspace_core.read_text config (schedules_recovery_path config) in
  check string "corrupt primary preserved" primary_before primary_after;
  check string "corrupt recovery preserved" recovery_before recovery_after
;;

let test_insert_surfaces_primary_write_failure () =
  with_workspace
  @@ fun config ->
  (* A directory at schedules_path breaks the *read* load_for_mutation does
     before ever reaching write_state (Eio.Io reports "Is a directory" on the
     readv, which load classifies as Corrupt_ledger) - it never exercises the
     write-failure path this test names. Inject a write-only failure instead:
     the ledger directory itself is made read-only *after* the (nonexistent-
     file) read succeeds, so save_file_atomic's temp-file creation for
     the write is what fails. *)
  let masc_dir = Workspace_utils.masc_dir config in
  Unix.chmod masc_dir 0o500;
  Fun.protect
    ~finally:(fun () -> Unix.chmod masc_dir 0o755)
    (fun () ->
       let request =
         make_request ~schedule_id:"persist-fail" ()
       in
       match insert_request config request with
       | Error (Persistence_failed msg) ->
         check bool "failure detail is surfaced" true (String.length msg > 0)
       | Error err ->
         fail ("expected Persistence_failed, got: " ^ store_error_to_string err)
       | Ok _ -> fail "insert unexpectedly succeeded when the ledger dir is read-only")
;;

let test_insert_keeps_primary_commit_when_recovery_write_fails () =
  with_workspace
  @@ fun config ->
  (* A directory at the mirror path breaks the mirror *write*. It also breaks the
     mirror *read*, and load probes the mirror whenever the primary is absent, so
     the injection needs a parseable primary in place first: load then resolves
     from the primary and never reaches the probe, leaving write_state's mirror
     write as the only failing step this test names. *)
  let committed = make_request ~schedule_id:"recovery-mirror-committed" () in
  ignore (insert_ok config committed);
  Workspace_core.delete_path config (schedules_recovery_path config);
  Unix.mkdir (schedules_recovery_path config) 0o755;
  let request =
    make_request ~schedule_id:"recovery-mirror-fail" ()
  in
  (match insert_request config request with
   | Ok stored -> check string "stored id" request.schedule_id stored.schedule_id
   | Error err ->
     fail
       ("recovery mirror failure should not fail committed primary write: "
        ^ store_error_to_string err));
  (match get_schedule config ~schedule_id:request.schedule_id with
   | Some stored -> check string "primary has schedule" request.schedule_id stored.schedule_id
   | None -> fail "primary schedule missing after recovery mirror failure");
  match get_schedule config ~schedule_id:committed.schedule_id with
  | Some stored ->
    check string "primary keeps the earlier schedule" committed.schedule_id
      stored.schedule_id
  | None -> fail "earlier schedule lost after recovery mirror failure"
;;

let test_cancel_refused_on_corrupt_ledger () =
  with_workspace
  @@ fun config ->
  let req = make_request ~schedule_id:"cancel-corrupt" () in
  ignore (insert_ok config req);
  corrupt_both config;
  match cancel_request config ~schedule_id:"cancel-corrupt" with
  | Ok _ -> fail "cancel on corrupt ledger unexpectedly succeeded"
  | Error (Corrupt_ledger _) -> ()
  | Error err -> fail ("expected Corrupt_ledger, got: " ^ store_error_to_string err)
;;

(* [.last-good] must hold a parseable snapshot, never a mirror of corruption. *)
let test_last_good_is_parseable_after_good_write () =
  with_workspace
  @@ fun config ->
  let req = make_request () in
  ignore (insert_ok config req);
  let recovery_json = Workspace_core.read_json config (schedules_recovery_path config) in
  match Schedule_store.state_of_yojson recovery_json with
  | Ok state -> check int "last-good holds the schedule" 1 (List.length state.schedules)
  | Error msg -> fail (".last-good is not parseable: " ^ msg)
;;

(* The out-of-band-deletion arm of the same silent-failure-to-data-loss
   regression: [write_state] commits the primary and the .last-good mirror
   together, so an absent primary next to a parseable mirror is a deletion, not a
   fresh store. Reading it as an empty state let the next write mirror that empty
   state over the surviving copy. *)
let test_absent_primary_recovers_from_last_good () =
  with_workspace
  @@ fun config ->
  let req = make_request ~schedule_id:"vanished-primary" () in
  ignore (insert_ok config req);
  delete_primary config;
  let recovered = read_state config in
  check int "schedule recovered from last-good" 1 (List.length recovered.schedules);
  check string "recovered schedule id" req.schedule_id
    (List.hd recovered.schedules).schedule_id
;;

let test_absent_primary_write_restores_primary_without_dropping_schedules () =
  with_workspace
  @@ fun config ->
  let before_deletion = make_request ~schedule_id:"vanished-primary-write" () in
  ignore (insert_ok config before_deletion);
  delete_primary config;
  let after_deletion = make_request ~schedule_id:"added-after-deletion" () in
  ignore (insert_ok config after_deletion);
  check bool "primary ledger is restored by the next write" true
    (Workspace_utils.path_exists config (schedules_path config));
  check int "recovered and new schedule both persist" 2
    (List.length (read_state config).schedules);
  let mirror_json = Workspace_core.read_json config (recovery_path config) in
  match Schedule_store.state_of_yojson mirror_json with
  | Ok mirror ->
    check int "last-good keeps both schedules" 2 (List.length mirror.schedules)
  | Error msg -> fail (".last-good is not parseable: " ^ msg)
;;

let test_absent_primary_and_absent_mirror_reads_fresh () =
  with_workspace
  @@ fun config ->
  ignore (insert_ok config (make_request ()));
  delete_primary config;
  Workspace_core.delete_path config (recovery_path config);
  match read_state_result config with
  | Ok state ->
    check int "no schedules when both files are gone" 0 (List.length state.schedules);
    check int "no wakes when both files are gone" 0 (List.length state.wakes)
  | Error error -> fail (read_error_to_string error)
;;

let test_absent_primary_with_unparseable_mirror_is_corrupt () =
  with_workspace
  @@ fun config ->
  ignore (insert_ok config (make_request ()));
  Workspace_core.write_text config (recovery_path config) "}also not json";
  delete_primary config;
  let mirror_before = Workspace_core.read_text config (recovery_path config) in
  (match read_state_result config with
   | Error (Corrupt_read_ledger { primary_err; recovery_err }) ->
     check bool "absent primary is described" true (String.length primary_err > 0);
     check bool "mirror error reported" true (Option.is_some recovery_err)
   | Ok _ ->
     fail "absent primary with an unparseable mirror returned a readable state");
  (match insert_request config (make_request ~schedule_id:"sched-2" ()) with
   | Ok _ -> fail "insert unexpectedly succeeded against an unparseable mirror"
   | Error (Corrupt_ledger _) -> ()
   | Error err -> fail ("expected Corrupt_ledger, got: " ^ store_error_to_string err));
  check string "unparseable mirror preserved" mirror_before
    (Workspace_core.read_text config (recovery_path config));
  check bool "refused mutation did not recreate the primary" false
    (Workspace_utils.path_exists config (schedules_path config))
;;

let cancelled_request_with_wake_receipt config ~schedule_id =
  let request =
    make_request ~schedule_id ~recurrence:(Interval { interval_sec = 3600 }) ()
  in
  let stored = insert_ok config request in
  ignore (store_ok "refresh_due" (refresh_due config ~now:201.0));
  ignore
    (store_ok "start_due_candidate"
       (start_due_candidate config ~now:202.0 ~schedule_id:stored.schedule_id));
  let advanced =
    store_ok "accept_running" (accept_running config ~now:203.0 ~schedule_id:stored.schedule_id ())
  in
  check string "recurring request advanced past the occurrence" "scheduled"
    (schedule_status_to_string advanced.status);
  let cancelled =
    store_ok "cancel_request" (cancel_request config ~schedule_id:stored.schedule_id)
  in
  check string "request is terminal" "cancelled"
    (schedule_status_to_string cancelled.status);
  stored
;;

let test_prune_deletes_terminal_request_and_wake_receipt () =
  with_workspace
  @@ fun config ->
  ignore
    (cancelled_request_with_wake_receipt config ~schedule_id:"prune-completed-wake");
  let state, pruned = store_ok "prune_completed" (prune_completed config) in
  check int "terminal request is pruned" 1 pruned;
  check int "request row removed" 0 (List.length state.schedules);
  check int "wake receipt removed with it" 0 (List.length state.wakes)
;;

let test_prune_does_not_bind_orphan_receipt_to_reused_public_id () =
  with_workspace
  @@ fun config ->
  let old_request =
    make_request
      ~schedule_id:"prune-reused-public-id"
      ~recurrence:(Interval { interval_sec = 60 })
      ()
  in
  ignore (insert_ok config old_request);
  ignore (store_ok "refresh old request" (refresh_due config ~now:201.0));
  ignore
    (store_ok
       "start old occurrence"
       (start_due_candidate
          config
          ~now:202.0
          ~schedule_id:old_request.schedule_id));
  ignore
    (store_ok
       "dispatch old occurrence"
       (accept_running config ~now:203.0 ~schedule_id:old_request.schedule_id ()));
  let old_state = read_state config in
  Workspace_core.write_text
    config
    (schedules_path config)
    (Yojson.Safe.to_string
       (`Assoc
          [ "version", `Int old_state.version
          ; "updated_at", `Float old_state.updated_at
          ; "schedules", `List []
          ; ( "wakes"
            , `List
                (List.map
                   Schedule_domain.wake_record_to_yojson
                   old_state.wakes) )
          ]));
  let new_request = make_request ~schedule_id:old_request.schedule_id () in
  check bool "public ID reuse mints a new instance" false
    (String.equal
       old_request.schedule_instance_id
       new_request.schedule_instance_id);
  ignore (insert_ok config new_request);
  (match
     last_wake_for_schedule_instance
       (read_state config)
       ~schedule_instance_id:new_request.schedule_instance_id
       ~schedule_id:new_request.schedule_id
   with
   | None -> ()
   | Some _ -> fail "reused public ID inherited the prior instance wake");
  ignore
    (store_ok
       "cancel replacement request"
       (cancel_request config ~schedule_id:new_request.schedule_id));
  let state, pruned = store_ok "prune replacement request" (prune_completed config) in
  check int "old orphan does not retain replacement request" 1 pruned;
  check int "replacement request is removed" 0 (List.length state.schedules);
  check int "orphan wake is removed with its absent owner" 0
    (List.length state.wakes)
;;

let rejection_error = function
  | Ok _ -> None
  | Error error -> Some error
;;

let test_contract_vocabularies_own_strings_and_errors () =
  let cases =
    [ ("actor_kind",
       [ "human_operator"; "automated_actor"; "system" ],
       Schedule_contract_values.actor_kind_strings,
       (fun v -> Result.is_ok (Schedule_contract_values.actor_kind_of_string v)),
       rejection_error (Schedule_contract_values.actor_kind_of_string "nope"))
    ; ("schedule_status",
       [ "scheduled"; "due"; "running"; "succeeded"; "failed"; "cancelled"; "expired" ],
       Schedule_contract_values.schedule_status_strings,
       (fun v -> Result.is_ok (Schedule_contract_values.schedule_status_of_string v)),
       rejection_error (Schedule_contract_values.schedule_status_of_string "nope"))
    ; ("schedule_source",
       [ "operator_request"; "automated_request"; "system_request" ],
       Schedule_contract_values.schedule_source_strings,
       (fun v -> Result.is_ok (Schedule_contract_values.schedule_source_of_string v)),
       rejection_error (Schedule_contract_values.schedule_source_of_string "nope"))
    ; ("recurrence_kind",
       [ "one_shot"; "interval"; "daily"; "cron" ],
       Schedule_contract_values.recurrence_kind_strings,
       (fun v ->
          Result.is_ok (Schedule_contract_values.recurrence_kind_of_string v)),
       rejection_error
         (Schedule_contract_values.recurrence_kind_of_string "nope"))
    ; ("wake_status",
       [ "running"; "succeeded"; "failed" ],
       Schedule_contract_values.wake_status_strings,
       (fun v -> Result.is_ok (Schedule_contract_values.wake_status_of_string v)),
       rejection_error (Schedule_contract_values.wake_status_of_string "nope"))
    ]
  in
  List.iter
    (fun (field, expected, contract_strings, decodes, rejection) ->
      check (list string)
        (Printf.sprintf "%s has one canonical wire vocabulary" field)
        expected
        contract_strings;
      match rejection with
      | None -> Alcotest.failf "%s must reject \"nope\"" field
      | Some error ->
        check string
          (Printf.sprintf "%s names its field" field)
          field
          error.Schedule_contract_values.field;
        check string
          (Printf.sprintf "%s carries the rejected value" field)
          "nope"
          error.rejected;
        check (list string)
          (Printf.sprintf "%s carries exactly its accepted set" field)
          expected
          error.accepted;
        check string
          (Printf.sprintf "%s renders one correction hint" field)
          (Printf.sprintf
             "unknown %s: nope; accepted: %s"
             field
             (String.concat ", " expected))
          (Schedule_contract_values.decode_error_to_string error);
        List.iter
          (fun value ->
            check bool
              (Printf.sprintf "%s offers %s, which decodes" field value)
              true
              (decodes value))
          error.accepted)
    cases
;;

let () =
  run "Schedule_store"
    [
      ( "state",
        [
          test_case "insert persists and bumps version" `Quick
            test_insert_persists_and_bumps_version;
          test_case "duplicate insert rejected without bump" `Quick
            test_duplicate_insert_rejected_without_bump;
          test_case "update replaces active definition with fresh instance" `Quick
            test_update_replaces_active_definition_with_fresh_instance;
          test_case "update accepts due and refuses terminal" `Quick
            test_update_accepts_due_but_refuses_terminal_definition;
          test_case "update requires existing schedule" `Quick
            test_update_requires_an_existing_schedule;
          test_case "corrupt primary recovers from last-good" `Quick
            test_recovers_from_last_good;
        ] );
      ( "corruption",
        [
          test_case "absent ledger reads empty" `Quick
            test_read_empty_when_file_absent;
          test_case "both unparseable return read error" `Quick
            test_read_error_when_both_unparseable;
          test_case "startup recovery refuses corrupt ledger" `Quick
            test_startup_recovery_refuses_corrupt_ledger;
          test_case "read_state raises on corrupt ledger" `Quick
            test_read_state_raises_on_corrupt;
          test_case "absent mirror separates uninitialised from corrupt" `Quick
            test_absent_mirror_separates_uninitialised_from_corrupt;
          test_case "mutation refused and corrupt ledger preserved" `Quick
            test_mutation_refused_and_preserves_corrupt_ledger;
          test_case "primary write failure is surfaced" `Quick
            test_insert_surfaces_primary_write_failure;
          test_case "recovery mirror write failure preserves primary" `Quick
            test_insert_keeps_primary_commit_when_recovery_write_fails;
          test_case "cancel refused on corrupt ledger" `Quick
            test_cancel_refused_on_corrupt_ledger;
          test_case "last-good is parseable after good write" `Quick
            test_last_good_is_parseable_after_good_write;
          test_case "absent primary recovers from last-good" `Quick
            test_absent_primary_recovers_from_last_good;
          test_case "write after absent primary restores it without dropping schedules"
            `Quick
            test_absent_primary_write_restores_primary_without_dropping_schedules;
          test_case "absent primary and absent mirror read fresh" `Quick
            test_absent_primary_and_absent_mirror_reads_fresh;
          test_case "absent primary with unparseable mirror is corrupt" `Quick
            test_absent_primary_with_unparseable_mirror_is_corrupt;
        ] );
      ( "lifecycle",
        [
          test_case "non-scheduled initial status rejected" `Quick
            test_store_rejects_non_scheduled_initial_status;
          test_case "cancel request marks cancelled" `Quick
            test_cancel_request_marks_cancelled;
        ] );
      ( "due",
        [
          test_case "due candidates dispatch without scheduler authorization state" `Quick
            test_due_candidates_dispatch_without_scheduler_authorization_state;
          test_case "due candidate starts without authorization state" `Quick
            test_due_candidate_starts_without_authorization_state;
          test_case "refresh_due expires scheduled and due" `Quick
            test_refresh_due_expires_scheduled_and_due;
          test_case "reschedule due recurring rows" `Quick
            test_reschedule_due_recurring_advances_only_matching_recurring_rows;
          test_case "reschedule due cron rows" `Quick
            test_reschedule_due_cron_advances_to_next_match;
          test_case "start and accept persist wake record" `Quick
            test_start_and_accept_persist_wake_record;
          test_case "durable acceptance completes wake receipt" `Quick
            test_accept_running_completes_wake_receipt;
          test_case "startup recovery returns only running schedule to due" `Quick
            test_startup_recovery_returns_only_running_schedule_to_due;
          test_case "startup recovery ignores wall-clock rollback" `Quick
            test_startup_recovery_uses_exact_occurrence_across_clock_rollback;
          test_case "fail due candidate records failed wake" `Quick
            test_fail_due_candidate_records_failed_wake;
          test_case "recurring occurrences remain dispatchable" `Quick
            test_recurring_occurrences_remain_dispatchable;
          test_case "terminal wakes are bounded per schedule" `Quick
            test_terminal_wakes_are_bounded_per_schedule;
          test_case "prune deletes terminal request and wake receipt"
            `Quick test_prune_deletes_terminal_request_and_wake_receipt;
          test_case
            "prune scopes wake receipt ownership by schedule instance"
            `Quick
            test_prune_does_not_bind_orphan_receipt_to_reused_public_id;
          test_case "contract vocabularies own strings and errors" `Quick
            test_contract_vocabularies_own_strings_and_errors;
        ] );
    ]
;;
