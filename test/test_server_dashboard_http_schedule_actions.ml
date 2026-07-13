open Alcotest

let temp_dir () =
  let path = Filename.temp_file "schedule_prune_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun entry -> remove_tree (Filename.concat path entry));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_path with Sys_error _ -> ())
    (fun () ->
       let config = Workspace_core.default_config base_path in
       ignore (Workspace_core.init config ~agent_name:(Some "test"));
       f config)
;;

let actor id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Human_operator; display_name = Some id }
;;

let payload =
  `Assoc
    [ "kind", `String "consumer.note"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "text", `String "test" ]
    ]
;;

let create_schedule config schedule_id =
  match
    Schedule_service.create
      config
      ~schedule_id
      ~requested_at:100.0
      ~requested_by:(actor "requester")
      ~scheduled_by:(actor "scheduler")
      ~due_at:200.0
      ~payload
      ~source:Schedule_domain.Operator_request
      ()
  with
  | Ok request -> request
  | Error error -> fail (Schedule_service.service_error_to_string error)
;;

let test_prune_removes_terminal_schedule () =
  with_workspace
  @@ fun config ->
  let request = create_schedule config "dashboard-prune" in
  (match Schedule_service.cancel config ~schedule_id:request.schedule_id with
   | Ok _ -> ()
   | Error error -> fail (Schedule_service.service_error_to_string error));
  match
    Server_dashboard_http.dashboard_schedule_prune_http_json
      ~config
      ~operator_name:"dashboard-admin"
  with
  | Error message -> fail message
  | Ok json ->
    let open Yojson.Safe.Util in
    check int "one terminal schedule pruned" 1 (json |> member "pruned_count" |> to_int);
    check bool
      "schedule removed"
      true
      (Option.is_none (Schedule_store.get_schedule config ~schedule_id:request.schedule_id))
;;

let test_prune_requires_authenticated_operator () =
  with_workspace
  @@ fun config ->
  match
    Server_dashboard_http.dashboard_schedule_prune_http_json
      ~config
      ~operator_name:"  "
  with
  | Ok _ -> fail "blank operator must be rejected"
  | Error message ->
    check string
      "explicit authentication error"
      "authenticated operator is required"
      message
;;

let () =
  run
    "Server_dashboard_http_schedule_actions"
    [ ( "prune"
      , [ test_case "removes terminal schedules" `Quick test_prune_removes_terminal_schedule
        ; test_case
            "requires authenticated operator"
            `Quick
            test_prune_requires_authenticated_operator
        ] )
    ]
;;
