open Alcotest
open Masc
open Schedule_domain
open Schedule_runner
open Schedule_service

let temp_dir () =
  let path = Filename.temp_file "schedule_runner_test" "" in
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
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "test"));
  f config
;;

let human ?display_name id = { id; kind = Human_operator; display_name }

let payload_json text =
  `Assoc
    [ "kind", `String "consumer.note"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "text", `String text ]
    ]
;;

let create_ok
  ?(schedule_id = "sched-1")
  ?(risk_class = Read_only)
  ?approval_required
  config
  =
  match
    create config ~schedule_id ?approval_required ~requested_at:100.0
      ~requested_by:(human "requester") ~scheduled_by:(human "scheduler")
      ~due_at:200.0 ~payload:(payload_json "wake me") ~risk_class
      ~source:Operator_request ()
  with
  | Ok request -> request
  | Error err -> fail (service_error_to_string err)
;;

let tick_ok config ~now =
  match tick config ~now with
  | Ok result -> result
  | Error err -> fail (runner_error_to_string err)
;;

let check_kind label expected actual =
  check string label (signal_kind_to_string expected) (signal_kind_to_string actual)
;;

let test_tick_emits_due_candidate_once () =
  with_workspace
  @@ fun config ->
  let request = create_ok ~schedule_id:"read-1" config in
  let before_due = tick_ok config ~now:199.0 in
  check int "no early signal" 0 (List.length before_due.emitted);
  let due = tick_ok config ~now:201.0 in
  check int "one signal" 1 (List.length due.emitted);
  check int "one status transition" 1 due.due_changed;
  let signal = List.hd due.emitted in
  check_kind "kind" Due_candidate signal.kind;
  check string "schedule id" request.schedule_id signal.schedule_id;
  check string "payload digest"
    (Schedule_domain.payload_digest request.payload)
    signal.payload_digest;
  let repeated = tick_ok config ~now:202.0 in
  check int "dedupe repeated tick" 0 (List.length repeated.emitted);
  check int "durable signal count" 1 (List.length (read_recent_signals config 10))
;;

let test_tick_emits_approval_blocker_then_candidate_after_grant () =
  with_workspace
  @@ fun config ->
  let request =
    create_ok ~schedule_id:"write-1" ~risk_class:Workspace_write config
  in
  let blocked = tick_ok config ~now:201.0 in
  check int "blocked signal" 1 (List.length blocked.emitted);
  let blocked_signal = List.hd blocked.emitted in
  check_kind "blocked kind" Due_blocked_approval blocked_signal.kind;
  check string "blocked id" request.schedule_id blocked_signal.schedule_id;
  let blocked_again = tick_ok config ~now:202.0 in
  check int "blocked dedupe" 0 (List.length blocked_again.emitted);
  (match approve config ~schedule_id:request.schedule_id ~approved_by:(human "approver") () with
   | Ok _ -> ()
   | Error err -> fail (service_error_to_string err));
  let due = tick_ok config ~now:203.0 in
  check int "candidate after approval" 1 (List.length due.emitted);
  check_kind "candidate kind" Due_candidate (List.hd due.emitted).kind;
  check int "two durable signals" 2 (List.length (read_recent_signals config 10))
;;

let () =
  run "Schedule_runner"
    [ ( "tick",
        [ test_case "emits due candidate once" `Quick
            test_tick_emits_due_candidate_once
        ; test_case "emits approval blocker then candidate after grant" `Quick
            test_tick_emits_approval_blocker_then_candidate_after_grant
        ] )
    ]
;;
