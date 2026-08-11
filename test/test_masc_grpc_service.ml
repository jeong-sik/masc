(** Backend and cluster-root regressions for the gRPC workspace service. *)

module T = Masc_grpc_types

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let memory_config ~base_path ~cluster_name : Workspace_utils.config =
  let backend_config : Backend_types.config =
    { base_path =
        Workspace_utils_paths_backend.masc_root_dir_from
          ~base_path
          ~cluster_name
    ; node_id = "grpc-test-node"
    ; cluster_name
    ; pubsub_max_messages = 1000
    }
  in
  { Workspace_utils.base_path
  ; workspace_path = base_path
  ; lock_expiry_minutes = 30
  ; backend_config
  ; backend = Workspace_utils.Memory (Backend.Memory.create ())
  }
;;

let with_memory_workspace ~cluster_name f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-grpc-backend" (fun base_path ->
    let config = memory_config ~base_path ~cluster_name in
    f ~clock:(Eio.Stdenv.clock env) config)
;;

let service config =
  Masc_grpc_service.create_service
    ~workspace_config:config
    ~tool_dispatcher:(fun _tool _payload -> Ok "{}")
    ~lsp_dispatcher:(fun ~language_id:_ ~jsonrpc_request_json:_ ~workspace_root:_ ->
      Error "test stub")
;;

let bind_backend_only_agent config agent_type =
  ignore
    (Masc.Workspace.bind_session
       config
       ~agent_name:agent_type
       ~capabilities:[ "test" ]
       ());
  let agents_dir = Workspace_utils_paths_backend.agents_dir config in
  let prefix = Workspace_utils.safe_filename agent_type ^ "-" in
  let file =
    match
      Workspace_utils_paths_backend.list_dir config agents_dir
      |> List.find_opt (fun name ->
        Filename.check_suffix name ".json"
        && String.starts_with ~prefix name)
    with
    | Some file -> file
    | None -> Alcotest.failf "agent file missing for %s" agent_type
  in
  let path = Filename.concat agents_dir file in
  if Sys.file_exists path then Sys.remove path;
  Filename.chop_suffix file ".json"
;;

let test_get_status_reads_backend_only_agent () =
  with_memory_workspace ~cluster_name:"default" (fun ~clock:_ config ->
    ignore (Masc.Workspace.init config ~agent_name:None);
    let agent_name = bind_backend_only_agent config "backend-agent" in
    let service = service config in
    match Grpc_eio.Service.get_method service "GetStatus" with
    | Some { handler = `Unary handler; _ } ->
      let response = T.StatusResponse.of_bytes (handler "") in
      (match
         List.find_opt
           (fun (agent : T.agent_info) -> String.equal agent.name agent_name)
           response.agents
       with
       | Some agent ->
         Alcotest.(check string) "backend agent status" "active" agent.status
       | None ->
         Alcotest.failf
           "backend-only agent %s missing from GetStatus"
           agent_name)
    | _ -> Alcotest.fail "GetStatus unary handler missing")
;;

let test_heartbeat_uses_non_default_cluster_root () =
  with_memory_workspace ~cluster_name:"review-cluster" (fun ~clock config ->
    ignore (Masc.Workspace.init config ~agent_name:None);
    let agent_name = bind_backend_only_agent config "heartbeat-agent" in
    ignore
      (Masc.Workspace.add_task
         config
         ~title:"pending review task"
         ~priority:2
         ~description:"backend-only heartbeat regression");
    let service = service config in
    match Grpc_eio.Service.get_method service "Heartbeat" with
    | Some { handler = `Bidi handler; _ } ->
      Eio.Switch.run
      @@ fun sw ->
      let request_stream = Grpc_eio.Stream.create 16 in
      let response_stream = handler ~sw request_stream in
      Grpc_eio.Stream.add
        request_stream
        (T.HeartbeatPing.to_bytes
           { agent_name
           ; session_id = "session-1"
           ; timestamp_ms = 1700000000000L
           ; current_task_id = ""
           });
      let ack_bytes =
        Eio.Time.with_timeout_exn clock 1.0 (fun () ->
          Grpc_eio.Stream.take response_stream)
      in
      let ack = T.HeartbeatAck.of_bytes ack_bytes in
      Alcotest.(check int) "non-default active agents" 1 ack.active_agent_count;
      Alcotest.(check int) "non-default pending tasks" 1 ack.pending_task_count;
      Grpc_eio.Stream.close request_stream
    | _ -> Alcotest.fail "Heartbeat bidi handler missing")
;;

let () =
  Alcotest.run
    "masc_grpc_service_backend"
    [ ( "backend"
      , [ Alcotest.test_case
            "GetStatus reads backend-only agent"
            `Quick
            test_get_status_reads_backend_only_agent
        ; Alcotest.test_case
            "Heartbeat uses non-default cluster root"
            `Quick
            test_heartbeat_uses_non_default_cluster_root
        ] ) ]
;;
