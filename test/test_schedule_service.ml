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
    ; "body", `Assoc [ "text", `String "do later" ]
    ]
;;

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

let test_create_mints_schedule_id () =
  with_workspace
  @@ fun config ->
  let first = create_ok config in
  let second = create_ok config in
  check bool "schedule id prefix" true (has_prefix "sched-" first.schedule_id);
  check bool "schedule ids are unique" true
    (not (String.equal first.schedule_id second.schedule_id));
  check_status "starts scheduled" Scheduled first.status
;;

let () =
  run "Schedule_service"
    [
      ( "create",
        [
          test_case "create mints schedule id" `Quick test_create_mints_schedule_id;
        ] );
    ]
;;
