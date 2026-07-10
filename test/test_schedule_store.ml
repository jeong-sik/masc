open Alcotest
open Schedule_domain
open Schedule_store

let temp_dir () =
  let path = Filename.temp_file "schedule_store_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  f config
;;

let schedules_recovery_path config = schedules_path config ^ ".last-good"

let human ?display_name id = { id; kind = Human_operator; display_name }

let payload_json () =
  `Assoc
    [ "kind", `String "consumer.note"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "text", `String "ship later" ]
    ]
;;

let updated_payload_json () =
  `Assoc
    [ "kind", `String "consumer.note"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "text", `String "ship now" ]
    ]
;;

let payload_exn json =
  match payload_of_yojson json with
  | Ok payload -> payload
  | Error msg -> fail msg
;;

let updated_payload () = payload_exn (updated_payload_json ())

let make_request
  ?(schedule_id = "sched-1")
  ?(risk_class = Workspace_write)
  ?expires_at
  ?recurrence
  ()
  =
  match
    create_request ~schedule_id ~requested_by:(human "requester")
      ~scheduled_by:(human "scheduler") ~requested_at:100.0 ~due_at:200.0
      ?expires_at ~payload:(payload_json ()) ~risk_class ~approval_required:false
      ~source:Operator_request ?recurrence ()
  with
  | Ok request -> request
  | Error msg -> fail msg
;;

let grant ?(approved_by = human "approver") ?(scope = Grant_occurrence) request =
  create_execution_grant ~grant_id:"grant-1" ~approved_by ~approved_at:150.0
    ~decision:Approve ~scope request
;;

let insert_ok config request =
  match insert_request config request with
  | Ok stored -> stored
  | Error err -> fail (store_error_to_string err)
;;

let check_error label expected = function
  | Ok _ -> fail (label ^ ": expected error")
  | Error actual ->
    check string label (store_error_to_string expected) (store_error_to_string actual)
;;

let check_status label expected actual =
  check string label (schedule_status_to_string expected) (schedule_status_to_string actual)
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
  check_status "stored pending" Pending_approval (List.hd after.schedules).status
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

let test_store_rejects_side_effecting_scheduled_insert () =
  with_workspace
  @@ fun config ->
  let req = { (make_request ()) with status = Scheduled } in
  match insert_request config req with
  | Ok _ -> fail "expected invalid initial status"
  | Error (Invalid_initial_status _) -> ()
  | Error err -> fail (store_error_to_string err)
;;

let test_grant_records_and_schedules_request () =
  with_workspace
  @@ fun config ->
  let req = make_request () in
  ignore (insert_ok config req);
  let grant = grant req in
  (match record_grant config grant with
   | Ok updated -> check_status "approved status" Scheduled updated.status
   | Error err -> fail (store_error_to_string err));
  let after = read_state config in
  check int "grant recorded" 1 (List.length after.grants);
  match get_schedule config ~schedule_id:req.schedule_id with
  | Some stored -> check_status "stored scheduled" Scheduled stored.status
  | None -> fail "schedule missing"
;;

let test_cancel_request_marks_cancelled () =
  with_workspace
  @@ fun config ->
  let req = make_request ~schedule_id:"cancel-1" ~risk_class:Read_only () in
  ignore (insert_ok config req);
  (match cancel_request config ~schedule_id:req.schedule_id with
   | Ok updated -> check_status "cancelled status" Cancelled updated.status
   | Error err -> fail (store_error_to_string err));
  match get_schedule config ~schedule_id:req.schedule_id with
  | Some stored -> check_status "stored cancelled" Cancelled stored.status
  | None -> fail "schedule missing"
;;

let test_update_request_updates_pending_and_scheduled () =
  with_workspace
  @@ fun config ->
  let pending = make_request ~schedule_id:"update-pending" () in
  let scheduled =
    make_request ~schedule_id:"update-scheduled" ~risk_class:Read_only ()
  in
  ignore (insert_ok config pending);
  ignore (insert_ok config scheduled);
  let payload_json = updated_payload_json () in
  let payload = payload_exn payload_json in
  (match
     update_request config ~schedule_id:pending.schedule_id ~due_at:250.0
       ~expires_at:(Some 300.0) ~payload
   with
   | Ok updated ->
     check_status "pending stays pending" Pending_approval updated.status;
     check (float 0.001) "pending due_at" 250.0 updated.due_at;
     check (option (float 0.001)) "pending expires_at" (Some 300.0)
       updated.expires_at;
     check string "pending payload" (Yojson.Safe.to_string payload_json)
       (Yojson.Safe.to_string (payload_to_yojson updated.payload))
   | Error err -> fail (store_error_to_string err));
  (match
     update_request config ~schedule_id:scheduled.schedule_id ~due_at:260.0
       ~expires_at:None ~payload
   with
   | Ok updated ->
     check_status "scheduled stays scheduled" Scheduled updated.status;
     check (float 0.001) "scheduled due_at" 260.0 updated.due_at;
     check (option (float 0.001)) "scheduled expires_at" None updated.expires_at;
     check string "scheduled payload" (Yojson.Safe.to_string payload_json)
       (Yojson.Safe.to_string (payload_to_yojson updated.payload))
   | Error err -> fail (store_error_to_string err))
;;

let update_not_allowed_error =
  Invalid_status_transition "only pending or scheduled requests can be updated"
;;

let test_update_request_rejects_running_and_terminal () =
  with_workspace
  @@ fun config ->
  let running = make_request ~schedule_id:"update-running" ~risk_class:Read_only () in
  ignore (insert_ok config running);
  (match refresh_due config ~now:201.0 with
   | Ok _ -> ()
   | Error err -> fail (store_error_to_string err));
  (match start_due_candidate config ~now:202.0 ~schedule_id:running.schedule_id with
   | Ok stored -> check_status "running" Running stored.status
   | Error err -> fail (store_error_to_string err));
  let before_running = read_state config in
  check_error "running update" update_not_allowed_error
    (update_request config ~schedule_id:running.schedule_id ~due_at:250.0
       ~expires_at:None ~payload:(updated_payload ()));
  let after_running = read_state config in
  check int "running version unchanged" before_running.version after_running.version;
  let terminal =
    make_request ~schedule_id:"update-terminal" ~risk_class:Read_only ()
  in
  ignore (insert_ok config terminal);
  (match cancel_request config ~schedule_id:terminal.schedule_id with
   | Ok stored -> check_status "cancelled" Cancelled stored.status
   | Error err -> fail (store_error_to_string err));
  let before_terminal = read_state config in
  check_error "terminal update" update_not_allowed_error
    (update_request config ~schedule_id:terminal.schedule_id ~due_at:250.0
       ~expires_at:None ~payload:(updated_payload ()));
  let after_terminal = read_state config in
  check int "terminal version unchanged" before_terminal.version after_terminal.version
;;

let test_requester_grant_rejected_without_bump () =
  with_workspace
  @@ fun config ->
  let req = make_request () in
  ignore (insert_ok config req);
  let before = read_state config in
  let grant = grant ~approved_by:req.requested_by req in
  check_error "requester grant"
    (Grant_validation_failed Approver_is_requester)
    (record_grant config grant);
  let after = read_state config in
  check int "version unchanged" before.version after.version;
  check int "no grant recorded" 0 (List.length after.grants)
;;

let test_due_candidates_require_approval_grant () =
  with_workspace
  @@ fun config ->
  let req = make_request () in
  ignore (insert_ok config req);
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "pending not due" 0 changed
   | Error err -> fail (store_error_to_string err));
  check int "no candidate before grant" 0
    (List.length (due_execution_candidates (read_state config)));
  (match record_grant config (grant req) with
   | Ok _ -> ()
   | Error err -> fail (store_error_to_string err));
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "scheduled became due" 1 changed
   | Error err -> fail (store_error_to_string err));
  let candidates = due_execution_candidates (read_state config) in
  check int "one candidate after grant" 1 (List.length candidates)
;;

let test_read_only_due_candidate_does_not_need_grant () =
  with_workspace
  @@ fun config ->
  let req = make_request ~schedule_id:"read-1" ~risk_class:Read_only () in
  ignore (insert_ok config req);
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "read only due" 1 changed
   | Error err -> fail (store_error_to_string err));
  check int "read-only candidate" 1
    (List.length (due_execution_candidates (read_state config)))
;;

let test_update_request_rejects_due_without_orphaning_grant () =
  with_workspace
  @@ fun config ->
  let req = make_request ~schedule_id:"update-due-granted" () in
  ignore (insert_ok config req);
  (match record_grant config (grant req) with
   | Ok stored -> check_status "approved status" Scheduled stored.status
   | Error err -> fail (store_error_to_string err));
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "became due" 1 changed
   | Error err -> fail (store_error_to_string err));
  let before = read_state config in
  let due =
    match get_schedule config ~schedule_id:req.schedule_id with
    | Some due -> due
    | None -> fail "due request missing"
  in
  check_status "stored due" Due due.status;
  check bool "approved grant is current before update" true
    (has_current_approved_grant before due);
  check int "candidate before update" 1
    (List.length (due_execution_candidates before));
  check_error "due update" update_not_allowed_error
    (update_request config ~schedule_id:req.schedule_id ~due_at:250.0
       ~expires_at:None ~payload:(updated_payload ()));
  let after = read_state config in
  let stored =
    match get_schedule config ~schedule_id:req.schedule_id with
    | Some stored -> stored
    | None -> fail "stored due request missing"
  in
  check int "version unchanged" before.version after.version;
  check_status "still due" Due stored.status;
  check (float 0.001) "due_at unchanged" 200.0 stored.due_at;
  check string "payload unchanged" (Yojson.Safe.to_string (payload_json ()))
    (Yojson.Safe.to_string (payload_to_yojson stored.payload));
  check bool "approved grant remains current" true
    (has_current_approved_grant after stored);
  check int "candidate preserved after rejected update" 1
    (List.length (due_execution_candidates after))
;;

let test_refresh_due_expires_pending_scheduled_and_due () =
  with_workspace
  @@ fun config ->
  let pending =
    make_request ~schedule_id:"expire-pending" ~risk_class:Workspace_write
      ~expires_at:150.0 ()
  in
  let scheduled =
    make_request ~schedule_id:"expire-scheduled" ~risk_class:Read_only
      ~expires_at:150.0 ()
  in
  let due =
    make_request ~schedule_id:"expire-due" ~risk_class:Read_only
      ~expires_at:250.0 ()
  in
  ignore (insert_ok config pending);
  ignore (insert_ok config scheduled);
  ignore (insert_ok config due);
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "pending expired, scheduled expired, due marked" 3 changed
   | Error err -> fail (store_error_to_string err));
  (match refresh_due config ~now:251.0 with
   | Ok (_, changed) -> check int "due expired" 1 changed
   | Error err -> fail (store_error_to_string err));
  (match
     get_schedule config ~schedule_id:"expire-pending",
     get_schedule config ~schedule_id:"expire-scheduled",
     get_schedule config ~schedule_id:"expire-due"
   with
   | Some pending, Some scheduled, Some due ->
     check_status "pending expired" Expired pending.status;
     check_status "scheduled expired" Expired scheduled.status;
     check_status "due expired" Expired due.status;
     check int "expired schedules are not due candidates" 0
       (List.length (due_execution_candidates (read_state config)))
   | _ -> fail "expired schedules missing")
;;

let test_reschedule_due_recurring_advances_only_matching_recurring_rows () =
  with_workspace
  @@ fun config ->
  let recurring =
    make_request ~schedule_id:"loop-1" ~risk_class:Read_only
      ~recurrence:(Interval { interval_sec = 60 })
      ()
  in
  let one_shot = make_request ~schedule_id:"once-1" ~risk_class:Read_only () in
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
    make_request ~schedule_id:"cron-1" ~risk_class:Read_only
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
  let req = make_request ~risk_class:Read_only () in
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

let test_load_fresh_when_file_absent () =
  with_workspace
  @@ fun config ->
  (* A pristine workspace has no schedules.json yet. *)
  (match Schedule_store.load config with
   | Fresh -> ()
   | Loaded _ -> fail "absent ledger reported as Loaded"
   | Corrupt _ -> fail "absent ledger reported as Corrupt");
  let state = read_state config in
  check int "fresh store has no schedules" 0 (List.length state.schedules);
  check int "fresh store has no grants" 0 (List.length state.grants);
  check int "fresh store has no executions" 0 (List.length state.executions)
;;

let test_start_and_complete_persist_execution_record () =
  with_workspace
  @@ fun config ->
  let req = make_request ~schedule_id:"exec-1" ~risk_class:Read_only () in
  ignore (insert_ok config req);
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "became due" 1 changed
   | Error err -> fail (store_error_to_string err));
  (match start_due_candidate config ~now:202.0 ~schedule_id:req.schedule_id with
   | Ok running -> check_status "running" Running running.status
   | Error err -> fail (store_error_to_string err));
  let running_state = read_state config in
  check int "one execution" 1 (List.length running_state.executions);
  let execution = List.hd running_state.executions in
  check string "execution status" "running"
    (execution_status_to_string execution.status);
  check string "execution schedule" req.schedule_id execution.schedule_id;
  check (float 0.001) "started at" 202.0 execution.started_at;
  check (float 0.001) "execution due" 200.0 execution.due_at;
  check string "payload digest" (payload_digest req.payload)
    execution.payload_digest;
  (match
     complete_running config ~now:203.0 ~schedule_id:req.schedule_id
       ~detail:(`Assoc [ "kind", `String "test.done" ])
       ()
   with
   | Ok stored -> check_status "succeeded" Succeeded stored.status
   | Error err -> fail (store_error_to_string err));
  let completed_state = read_state config in
  match
    last_execution_for_schedule completed_state ~schedule_id:req.schedule_id
  with
  | None -> fail "missing completed execution"
  | Some completed ->
    check string "completed status" "succeeded"
      (execution_status_to_string completed.status);
    check (option (float 0.001)) "finished at" (Some 203.0)
      completed.finished_at;
    (match completed.detail with
     | Some (`Assoc fields) ->
       (match List.assoc_opt "kind" fields with
        | Some (`String kind) -> check string "detail kind" "test.done" kind
        | _ -> fail "detail kind missing")
     | _ -> fail "detail missing")
;;

let test_fail_due_candidate_records_failed_execution () =
  with_workspace
  @@ fun config ->
  let req = make_request ~schedule_id:"unsupported-1" ~risk_class:Read_only () in
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
     last_execution_for_schedule (read_state config) ~schedule_id:req.schedule_id
   with
   | None -> fail "missing failed execution"
   | Some execution ->
     check string "failed execution status" "failed"
       (execution_status_to_string execution.status);
     check (option string) "failed execution error" (Some "unsupported payload")
       execution.error;
     check (option (float 0.001)) "finished at" (Some 202.0)
       execution.finished_at)
;;

let test_recurring_grant_is_scoped_to_current_due_at () =
  with_workspace
  @@ fun config ->
  let req =
    make_request ~schedule_id:"write-loop-1" ~risk_class:Workspace_write
      ~recurrence:(Interval { interval_sec = 60 })
      ()
  in
  ignore (insert_ok config req);
  (match record_grant config (grant req) with
   | Ok stored -> check_status "approved first occurrence" Scheduled stored.status
   | Error err -> fail (store_error_to_string err));
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "first due" 1 changed
   | Error err -> fail (store_error_to_string err));
  check int "first occurrence candidate" 1
    (List.length (due_execution_candidates (read_state config)));
  (match start_due_candidate config ~now:202.0 ~schedule_id:req.schedule_id with
   | Ok running -> check_status "running first occurrence" Running running.status
   | Error err -> fail (store_error_to_string err));
  (match complete_running config ~now:203.0 ~schedule_id:req.schedule_id () with
   | Ok stored ->
     check_status "rescheduled" Scheduled stored.status;
     check (float 0.001) "next due" 260.0 stored.due_at
   | Error err -> fail (store_error_to_string err));
  (match refresh_due config ~now:260.0 with
   | Ok (_, changed) -> check int "second due" 1 changed
   | Error err -> fail (store_error_to_string err));
  let state = read_state config in
  let due =
    match get_schedule config ~schedule_id:req.schedule_id with
    | Some due -> due
    | None -> fail "rescheduled request missing"
  in
  check bool "old grant is stale" false (has_current_approved_grant state due);
  check int "second occurrence blocked before fresh grant" 0
    (List.length (due_execution_candidates state));
  let fresh_grant =
    create_execution_grant ~grant_id:"grant-2" ~approved_by:(human "approver-2")
      ~approved_at:261.0 ~decision:Approve ~scope:Grant_occurrence due
  in
  (match record_grant config fresh_grant with
   | Ok stored -> check_status "fresh due grant keeps due" Due stored.status
   | Error err -> fail (store_error_to_string err));
  check int "second occurrence candidate after fresh grant" 1
    (List.length (due_execution_candidates (read_state config)))
;;

(* The standing counterpart of the test above: one approval covers every
   later occurrence of the SAME payload digest, and stops covering as soon
   as the payload (and therefore the digest) changes. This is the fix for
   the live friction where a recurring workspace_write wake re-blocked on a
   human click for every single occurrence of an unchanged action. *)
let test_standing_grant_covers_recurrences_until_payload_changes () =
  with_workspace
  @@ fun config ->
  let req =
    make_request ~schedule_id:"write-loop-standing" ~risk_class:Workspace_write
      ~recurrence:(Interval { interval_sec = 60 })
      ()
  in
  ignore (insert_ok config req);
  (match record_grant config (grant ~scope:Grant_standing req) with
   | Ok stored -> check_status "approved with standing scope" Scheduled stored.status
   | Error err -> fail (store_error_to_string err));
  (match refresh_due config ~now:201.0 with
   | Ok (_, changed) -> check int "first due" 1 changed
   | Error err -> fail (store_error_to_string err));
  (match start_due_candidate config ~now:202.0 ~schedule_id:req.schedule_id with
   | Ok running -> check_status "running first occurrence" Running running.status
   | Error err -> fail (store_error_to_string err));
  (match complete_running config ~now:203.0 ~schedule_id:req.schedule_id () with
   | Ok stored -> check_status "rescheduled" Scheduled stored.status
   | Error err -> fail (store_error_to_string err));
  (match refresh_due config ~now:260.0 with
   | Ok (_, changed) -> check int "second due" 1 changed
   | Error err -> fail (store_error_to_string err));
  let state = read_state config in
  let due =
    match get_schedule config ~schedule_id:req.schedule_id with
    | Some due -> due
    | None -> fail "rescheduled request missing"
  in
  check bool "standing grant still current on second occurrence" true
    (has_current_approved_grant state due);
  check int "second occurrence dispatches without a fresh grant" 1
    (List.length (due_execution_candidates state));
  (* Change the action: digest moves, standing grant must stop matching. *)
  (match
     update_request config ~schedule_id:req.schedule_id ~due_at:due.due_at
       ~expires_at:None ~payload:(updated_payload ())
   with
   | Ok _ -> ()
   | Error err -> fail (store_error_to_string err));
  let state = read_state config in
  let updated =
    match get_schedule config ~schedule_id:req.schedule_id with
    | Some updated -> updated
    | None -> fail "updated request missing"
  in
  check bool "standing grant dies with the payload digest" false
    (has_current_approved_grant state updated)
;;

let test_load_corrupt_when_both_unparseable () =
  with_workspace
  @@ fun config ->
  let req = make_request ~risk_class:Read_only () in
  ignore (insert_ok config req);
  corrupt_both config;
  match Schedule_store.load config with
  | Corrupt { primary_err; recovery_err } ->
    check bool "primary error is non-empty" true (String.length primary_err > 0);
    check bool "recovery error reported" true (Option.is_some recovery_err)
  | Fresh -> fail "corrupt-but-present ledger reported as Fresh"
  | Loaded _ -> fail "corrupt ledger reported as Loaded"
;;

let test_read_state_raises_on_corrupt () =
  with_workspace
  @@ fun config ->
  let req = make_request ~risk_class:Read_only () in
  ignore (insert_ok config req);
  corrupt_both config;
  match read_state config with
  | _ -> fail "read_state silently returned a state for a corrupt ledger"
  | exception Schedule_store.Corrupt_ledger_exn _ -> ()
;;

(* The core silent-failure-to-data-loss regression: a mutation on a corrupt
   ledger must be refused (typed [Corrupt_ledger]) and must NOT overwrite the
   present-but-corrupt files with an empty default. *)
let test_mutation_refused_and_preserves_corrupt_ledger () =
  with_workspace
  @@ fun config ->
  let req = make_request ~risk_class:Read_only () in
  ignore (insert_ok config req);
  corrupt_both config;
  let primary_before = Workspace_core.read_text config (schedules_path config) in
  let recovery_before = Workspace_core.read_text config (schedules_recovery_path config) in
  (match insert_request config (make_request ~schedule_id:"sched-2" ~risk_class:Read_only ()) with
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
     file / Fresh) read succeeds, so save_file_atomic's temp-file creation for
     the write is what fails. *)
  let masc_dir = Workspace_utils.masc_dir config in
  Unix.chmod masc_dir 0o500;
  Fun.protect
    ~finally:(fun () -> Unix.chmod masc_dir 0o755)
    (fun () ->
       let request =
         make_request ~schedule_id:"persist-fail" ~risk_class:Read_only ()
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
  Unix.mkdir (schedules_recovery_path config) 0o755;
  let request =
    make_request ~schedule_id:"recovery-mirror-fail" ~risk_class:Read_only ()
  in
  (match insert_request config request with
   | Ok stored -> check string "stored id" request.schedule_id stored.schedule_id
   | Error err ->
     fail
       ("recovery mirror failure should not fail committed primary write: "
        ^ store_error_to_string err));
  match get_schedule config ~schedule_id:request.schedule_id with
  | Some stored -> check string "primary has schedule" request.schedule_id stored.schedule_id
  | None -> fail "primary schedule missing after recovery mirror failure"
;;

let test_cancel_refused_on_corrupt_ledger () =
  with_workspace
  @@ fun config ->
  let req = make_request ~schedule_id:"cancel-corrupt" ~risk_class:Read_only () in
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
  let req = make_request ~risk_class:Read_only () in
  ignore (insert_ok config req);
  let recovery_json = Workspace_core.read_json config (schedules_recovery_path config) in
  match Schedule_store.state_of_yojson recovery_json with
  | Ok state -> check int "last-good holds the schedule" 1 (List.length state.schedules)
  | Error msg -> fail (".last-good is not parseable: " ^ msg)
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
          test_case "corrupt primary recovers from last-good" `Quick
            test_recovers_from_last_good;
        ] );
      ( "corruption",
        [
          test_case "absent ledger loads Fresh" `Quick
            test_load_fresh_when_file_absent;
          test_case "both unparseable loads Corrupt" `Quick
            test_load_corrupt_when_both_unparseable;
          test_case "read_state raises on corrupt ledger" `Quick
            test_read_state_raises_on_corrupt;
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
        ] );
      ( "approval",
        [
          test_case "side-effecting scheduled insert rejected" `Quick
            test_store_rejects_side_effecting_scheduled_insert;
          test_case "grant records and schedules request" `Quick
            test_grant_records_and_schedules_request;
          test_case "cancel request marks cancelled" `Quick
            test_cancel_request_marks_cancelled;
          test_case "update request updates pending and scheduled" `Quick
            test_update_request_updates_pending_and_scheduled;
          test_case "update request rejects running and terminal" `Quick
            test_update_request_rejects_running_and_terminal;
          test_case "requester grant rejected without bump" `Quick
            test_requester_grant_rejected_without_bump;
        ] );
      ( "due",
        [
          test_case "due candidates require approval grant" `Quick
            test_due_candidates_require_approval_grant;
          test_case "read-only due candidate does not need grant" `Quick
            test_read_only_due_candidate_does_not_need_grant;
          test_case "update request rejects due without orphaning grant" `Quick
            test_update_request_rejects_due_without_orphaning_grant;
          test_case "refresh_due expires pending scheduled and due" `Quick
            test_refresh_due_expires_pending_scheduled_and_due;
          test_case "reschedule due recurring rows" `Quick
            test_reschedule_due_recurring_advances_only_matching_recurring_rows;
          test_case "reschedule due cron rows" `Quick
            test_reschedule_due_cron_advances_to_next_match;
          test_case "start and complete persist execution record" `Quick
            test_start_and_complete_persist_execution_record;
          test_case "fail due candidate records failed execution" `Quick
            test_fail_due_candidate_records_failed_execution;
          test_case "recurring grant is scoped to current due_at" `Quick
            test_recurring_grant_is_scoped_to_current_due_at;
          test_case "standing grant covers recurrences until payload changes"
            `Quick test_standing_grant_covers_recurrences_until_payload_changes;
        ] );
    ]
;;
