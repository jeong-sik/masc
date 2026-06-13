open Alcotest
open Masc
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
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "test"));
  f config
;;

let human ?display_name id = { id; kind = Human_operator; display_name }

let payload_json () =
  `Assoc
    [ "kind", `String "consumer.note"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "text", `String "ship later" ]
    ]
;;

let make_request ?(schedule_id = "sched-1") ?(risk_class = Workspace_write) () =
  match
    create_request ~schedule_id ~requested_by:(human "requester")
      ~scheduled_by:(human "scheduler") ~requested_at:100.0 ~due_at:200.0
      ~payload:(payload_json ()) ~risk_class ~approval_required:false
      ~source:Operator_request ()
  with
  | Ok request -> request
  | Error msg -> fail msg
;;

let grant ?(approved_by = human "approver") request =
  create_execution_grant ~grant_id:"grant-1" ~approved_by ~approved_at:150.0
    ~decision:Approve request
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

let test_recovers_from_last_good () =
  with_workspace
  @@ fun config ->
  let req = make_request ~risk_class:Read_only () in
  ignore (insert_ok config req);
  Workspace.write_text config (schedules_path config) "{not json";
  let recovered = read_state config in
  check int "recovered schedule" 1 (List.length recovered.schedules)
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
      ( "approval",
        [
          test_case "side-effecting scheduled insert rejected" `Quick
            test_store_rejects_side_effecting_scheduled_insert;
          test_case "grant records and schedules request" `Quick
            test_grant_records_and_schedules_request;
          test_case "requester grant rejected without bump" `Quick
            test_requester_grant_rejected_without_bump;
        ] );
      ( "due",
        [
          test_case "due candidates require approval grant" `Quick
            test_due_candidates_require_approval_grant;
          test_case "read-only due candidate does not need grant" `Quick
            test_read_only_due_candidate_does_not_need_grant;
        ] );
    ]
;;
