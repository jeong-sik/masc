open Alcotest

let temp_dir () =
  let path = Filename.temp_file "schedule_actions_test" "" in
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
      end
      else Sys.remove path
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

let human id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Human_operator; display_name = Some id }
;;

let payload_json text =
  `Assoc
    [ "kind", `String "consumer.note"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "text", `String text ]
    ]
;;

let create_ok ?(risk_class = Schedule_domain.Read_only) ~schedule_id config =
  match
    Schedule_service.create config ~schedule_id ~requested_at:100.0
      ~requested_by:(human "requester") ~scheduled_by:(human "scheduler")
      ~due_at:200.0 ~payload:(payload_json "before") ~risk_class
      ~source:Schedule_domain.Operator_request ()
  with
  | Ok request -> request
  | Error err -> fail (Schedule_service.service_error_to_string err)
;;

let resolve config args =
  Server_dashboard_http.dashboard_schedule_resolve_http_json
    ~config
    ~operator_name:"dashboard-admin"
    ~args
;;

let check_resolve_error label expected = function
  | Ok _ -> fail (label ^ ": expected error")
  | Error actual -> check string label expected actual
;;

let test_update_decision_updates_schedule () =
  with_workspace
  @@ fun config ->
  let request = create_ok ~schedule_id:"http-update-1" config in
  let payload = payload_json "after" in
  let args =
    `Assoc
      [ "schedule_id", `String request.schedule_id
      ; "decision", `String "update"
      ; "due_at", `Float 260.0
      ; "expires_at", `Float 360.0
      ; "payload", payload
      ]
  in
  match resolve config args with
  | Error message -> fail message
  | Ok json ->
    let open Yojson.Safe.Util in
    check string "decision" "update" (json |> member "decision" |> to_string);
    check string "approved_by" "dashboard-admin"
      (json |> member "approved_by" |> member "id" |> to_string);
    (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
     | None -> fail "schedule missing"
     | Some stored ->
       check string "status" "scheduled"
         (Schedule_domain.schedule_status_to_string stored.status);
       check (float 0.001) "due_at" 260.0 stored.due_at;
       check (option (float 0.001)) "expires_at" (Some 360.0)
         stored.expires_at;
       check string "payload" (Yojson.Safe.to_string payload)
         (Yojson.Safe.to_string (Schedule_domain.payload_to_yojson stored.payload)))
;;

let test_update_decision_validates_required_fields () =
  with_workspace
  @@ fun config ->
  let request = create_ok ~schedule_id:"http-update-validate" config in
  check_resolve_error "missing due_at" "due_at is required"
    (resolve config
       (`Assoc
         [ "schedule_id", `String request.schedule_id
         ; "decision", `String "update"
         ; "payload", payload_json "after"
         ]));
  check_resolve_error "payload object" "payload is required"
    (resolve config
       (`Assoc
         [ "schedule_id", `String request.schedule_id
         ; "decision", `String "update"
         ; "due_at", `Float 260.0
         ; "payload", `String "not an object"
         ]))
;;

let test_update_decision_reports_due_status_rejection () =
  with_workspace
  @@ fun config ->
  let request = create_ok ~schedule_id:"http-update-due" config in
  (match Schedule_service.due_candidates config ~now:201.0 with
   | Ok [ candidate ] ->
     check string "candidate id" request.schedule_id candidate.schedule_id
   | Ok candidates ->
     fail (Printf.sprintf "expected one candidate, got %d" (List.length candidates))
   | Error err -> fail (Schedule_service.service_error_to_string err));
  check_resolve_error "due update"
    "invalid schedule status transition: only pending or scheduled requests can be updated"
    (resolve config
       (`Assoc
         [ "schedule_id", `String request.schedule_id
         ; "decision", `String "update"
         ; "due_at", `Float 260.0
         ; "payload", payload_json "after"
         ]))
;;

let test_cancel_decision_marks_cancelled () =
  with_workspace
  @@ fun config ->
  let request = create_ok ~schedule_id:"http-cancel-1" config in
  let args =
    `Assoc
      [ "schedule_id", `String request.schedule_id
      ; "decision", `String "cancel"
      ]
  in
  match resolve config args with
  | Error message -> fail message
  | Ok json ->
    let open Yojson.Safe.Util in
    check string "decision" "cancel" (json |> member "decision" |> to_string);
    (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
     | None -> fail "schedule missing"
     | Some stored ->
       check string "status" "cancelled"
         (Schedule_domain.schedule_status_to_string stored.status))
;;

let () =
  run "Server_dashboard_http_schedule_actions"
    [ ( "update",
        [
          test_case "decision updates schedule" `Quick
            test_update_decision_updates_schedule;
          test_case "decision validates required fields" `Quick
            test_update_decision_validates_required_fields;
          test_case "decision reports due status rejection" `Quick
            test_update_decision_reports_due_status_rejection;
        ] );
      ( "cancel",
        [
          test_case "decision marks cancelled" `Quick
            test_cancel_decision_marks_cancelled;
        ] );
    ]
;;
