open Alcotest
open Schedule_domain
open Schedule_service

let temp_dir () =
  let path = Filename.temp_file "schedule_service_test" "" in
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

let human ?display_name id = { id; kind = Human_operator; display_name }

let payload_json () =
  `Assoc
    [ "kind", `String "consumer.note"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "text", `String "do later" ]
    ]
;;

let updated_payload_json () =
  `Assoc
    [ "kind", `String "consumer.note"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "text", `String "do now" ]
    ]
;;

let payload_exn json =
  match payload_of_yojson json with
  | Ok payload -> payload
  | Error msg -> fail msg
;;

let updated_payload () = payload_exn (updated_payload_json ())

let has_prefix prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.sub value 0 prefix_len = prefix
;;

let create_ok
  ?schedule_id
  config
  =
  match
    create config ?schedule_id ~requested_at:100.0
      ~requested_by:(human "requester") ~scheduled_by:(human "scheduler")
      ~due_at:200.0 ~payload:(payload_json ()) ~source:Operator_request ()
  with
  | Ok request -> request
  | Error err -> fail (service_error_to_string err)
;;

let check_status label expected actual =
  check string label (schedule_status_to_string expected) (schedule_status_to_string actual)
;;

let check_service_error label expected = function
  | Ok _ -> fail (label ^ ": expected error")
  | Error actual ->
    check string label (service_error_to_string expected) (service_error_to_string actual)
;;

let test_create_mints_schedule_id () =
  with_workspace
  @@ fun config ->
  let request = create_ok config in
  check bool "schedule id prefix" true (has_prefix "sched-" request.schedule_id);
  check_status "starts scheduled" Scheduled request.status
;;

let test_list_and_get_by_status () =
  with_workspace
  @@ fun config ->
  let cancelled = create_ok ~schedule_id:"cancelled-1" config in
  let scheduled = create_ok ~schedule_id:"scheduled-1" config in
  (match cancel config ~schedule_id:cancelled.schedule_id with
   | Ok _ -> ()
   | Error err -> fail (service_error_to_string err));
  check int "all schedules" 2 (List.length (list config ()));
  check int "scheduled only" 1 (List.length (list config ~status:Scheduled ()));
  check int "cancelled only" 1 (List.length (list config ~status:Cancelled ()));
  (match get config ~schedule_id:cancelled.schedule_id with
   | Some stored -> check string "cancelled id" cancelled.schedule_id stored.schedule_id
   | None -> fail "cancelled missing");
  (match get config ~schedule_id:scheduled.schedule_id with
   | Some stored -> check string "scheduled id" scheduled.schedule_id stored.schedule_id
   | None -> fail "scheduled missing")
;;

let test_update_scheduled_request () =
  with_workspace
  @@ fun config ->
  let request =
    create_ok ~schedule_id:"service-update-1" config
  in
  let payload_json = updated_payload_json () in
  let payload = payload_exn payload_json in
  match
    update config ~schedule_id:request.schedule_id ~due_at:260.0
      ~expires_at:(Some 360.0) ~payload
  with
  | Ok updated ->
    check_status "updated stays scheduled" Scheduled updated.status;
    check (float 0.001) "due_at" 260.0 updated.due_at;
    check (option (float 0.001)) "expires_at" (Some 360.0) updated.expires_at;
    check string "payload" (Yojson.Safe.to_string payload_json)
      (Yojson.Safe.to_string (payload_to_yojson updated.payload))
  | Error err -> fail (service_error_to_string err)
;;

let test_update_due_request_reports_store_error () =
  with_workspace
  @@ fun config ->
  let request =
    create_ok ~schedule_id:"service-update-due" config
  in
  (match due_candidates config ~now:201.0 with
   | Ok [ candidate ] -> check_status "candidate due" Due candidate.status
   | Ok candidates ->
     fail (Printf.sprintf "expected one candidate, got %d" (List.length candidates))
   | Error err -> fail (service_error_to_string err));
  check_service_error "due update"
    (Store_error
       (Schedule_store.Invalid_status_transition
          "only scheduled requests can be updated"))
    (update config ~schedule_id:request.schedule_id ~due_at:260.0
       ~expires_at:None ~payload:(updated_payload ()))
;;

let test_due_candidates_do_not_execute () =
  with_workspace
  @@ fun config ->
  let request = create_ok ~schedule_id:"due-1" config in
  match due_candidates config ~now:201.0 with
  | Ok [ candidate ] ->
    check string "candidate id" request.schedule_id candidate.schedule_id;
    check_status "candidate due" Due candidate.status
  | Ok candidates ->
    fail (Printf.sprintf "expected one candidate, got %d" (List.length candidates))
  | Error err -> fail (service_error_to_string err)
;;

let () =
  run "Schedule_service"
    [
      ( "create",
        [
          test_case "create mints schedule id" `Quick test_create_mints_schedule_id;
          test_case "list and get by status" `Quick test_list_and_get_by_status;
        ] );
      ( "update",
        [
          test_case "updates scheduled request" `Quick test_update_scheduled_request;
          test_case "due request reports store error" `Quick
            test_update_due_request_reports_store_error;
        ] );
      ( "due",
        [
          test_case "due candidates do not execute" `Quick
            test_due_candidates_do_not_execute;
        ] );
    ]
;;
