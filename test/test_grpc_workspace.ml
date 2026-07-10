(** Tests for MASC gRPC Workspace Service.

    Tests the types, service construction, and handler logic without
    requiring a running gRPC server or network connections.

    Wire format: protobuf binary (not JSON). Tests verify roundtrip
    serialization/deserialization via of_bytes/to_bytes. *)

module T = Masc_grpc_types

let malformed_protobuf = "\x0a\x05ab"

let latest_log_seq () =
  match Log.Ring.recent ~limit:1 () with
  | (entry : Log.Ring.entry) :: _ -> entry.seq
  | [] -> -1
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let create_worker_token base_path agent_name =
  match Auth.create_token base_path ~agent_name ~role:Masc_domain.Worker with
  | Ok (token, _credential) -> token
  | Error err -> Alcotest.fail (Masc_domain.masc_error_to_string err)
;;

let expect_grpc_status label expected f =
  match f () with
  | _ -> Alcotest.failf "%s: expected typed gRPC rejection" label
  | exception Grpc_core.Status.Grpc_error status ->
    Alcotest.(check bool) label true (status.Grpc_core.Status.code = expected)
  | exception exn ->
    Alcotest.failf "%s: unexpected exception %s" label (Printexc.to_string exn)
;;

(* ====== Type serialization/deserialization round-trip tests ====== *)

let test_subscribe_filter_request_roundtrip () =
  let req =
    T.SubscribeRequest.
      { agent_name = "claude-swift-fox"
      ; session_id = "grpc-session-001"
      ; event_types = [ "task"; "message"; "agent.session_bound" ]
      ; since_seq = 42L
      ; auth_token = "subscribe-token"
      }
  in
  let bytes = T.SubscribeRequest_serde.to_bytes req in
  let decoded = T.SubscribeRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" req.agent_name decoded.agent_name;
  Alcotest.(check string) "session_id" req.session_id decoded.session_id;
  Alcotest.(check (list string)) "event_types" req.event_types decoded.event_types;
  Alcotest.(check int64) "since_seq" req.since_seq decoded.since_seq
  ; Alcotest.(check string) "auth_token" req.auth_token decoded.auth_token
;;

let test_tool_call_dispatch_request_roundtrip () =
  let req =
    T.ToolCallRequest.
      { agent_name = "gemini-bright-owl"
      ; session_id = "grpc-gemini-12345"
      ; tool_name = "masc_status"
      ; arguments_json = {|{"_agent_name":"gemini-bright-owl"}|}
      ; auth_token = "tool-token"
      }
  in
  let bytes = T.ToolCallRequest.to_bytes req in
  let decoded = T.ToolCallRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" req.agent_name decoded.agent_name;
  Alcotest.(check string) "session_id" req.session_id decoded.session_id;
  Alcotest.(check string) "tool_name" req.tool_name decoded.tool_name;
  Alcotest.(check string) "arguments_json" req.arguments_json decoded.arguments_json
  ; Alcotest.(check string) "auth_token" req.auth_token decoded.auth_token
;;

let test_status_agents_response_roundtrip () =
  let resp =
    T.StatusResponse.
      { agents =
          [ { T.name = "claude-swift-fox"
            ; status = "active"
            ; capabilities = [ "code" ]
            ; last_seen_ms = 1700000000000L
            ; session_bound_at_ms = 1700000000000L
            ; current_task_id = "task-1"
            }
          ]
      ; tasks = []
      ; message_count = 0
      ; workspace_path = "/tmp/grpc-test"
      }
  in
  let bytes = T.StatusResponse.to_bytes resp in
  let decoded = T.StatusResponse.of_bytes bytes in
  Alcotest.(check int) "agents count" 1 (List.length decoded.agents);
  let agent = List.hd decoded.agents in
  Alcotest.(check string) "agent name" "claude-swift-fox" agent.T.name;
  Alcotest.(check string) "agent status" "active" agent.T.status;
  Alcotest.(check (list string)) "agent capabilities" [ "code" ] agent.T.capabilities
;;

let test_broadcast_request_roundtrip () =
  let req =
    T.BroadcastRequest.
      { agent_name = "codex-running-bear"
      ; message = "CI fixed, ready to merge"
      ; mentions = [ "claude"; "gemini" ]
      ; auth_token = "broadcast-token"
      }
  in
  let bytes = T.BroadcastRequest.to_bytes req in
  let decoded = T.BroadcastRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" req.agent_name decoded.agent_name;
  Alcotest.(check string) "message" req.message decoded.message;
  Alcotest.(check (list string)) "mentions" req.mentions decoded.mentions
  ; Alcotest.(check string) "auth_token" req.auth_token decoded.auth_token
;;

let test_broadcast_response_roundtrip () =
  let resp = T.BroadcastResponse.{ success = true; seq = 42L } in
  let bytes = T.BroadcastResponse.to_bytes resp in
  let decoded = T.BroadcastResponse.of_bytes bytes in
  Alcotest.(check bool) "success" true decoded.success;
  Alcotest.(check int64) "seq" 42L decoded.seq
;;

let test_heartbeat_ping_roundtrip () =
  let ping =
    T.HeartbeatPing.
      { agent_name = "test-agent"
      ; session_id = "sess-1"
      ; timestamp_ms = 1700000000000L
      ; current_task_id = "task-42"
      ; auth_token = "heartbeat-token"
      }
  in
  let bytes = T.HeartbeatPing.to_bytes ping in
  let decoded = T.HeartbeatPing.of_bytes bytes in
  Alcotest.(check string) "agent_name" "test-agent" decoded.agent_name;
  Alcotest.(check string) "session_id" "sess-1" decoded.session_id;
  Alcotest.(check int64) "timestamp_ms" 1700000000000L decoded.timestamp_ms;
  Alcotest.(check string) "current_task_id" "task-42" decoded.current_task_id
  ; Alcotest.(check string) "auth_token" "heartbeat-token" decoded.auth_token
;;

let test_heartbeat_ack_roundtrip () =
  let ack =
    T.HeartbeatAck.
      { timestamp_ms = 1700000000001L
      ; active_agent_count = 5
      ; pending_task_count = 3
      }
  in
  let bytes = T.HeartbeatAck.to_bytes ack in
  let decoded = T.HeartbeatAck.of_bytes bytes in
  Alcotest.(check int64) "timestamp_ms" 1700000000001L decoded.timestamp_ms;
  Alcotest.(check int) "active_agent_count" 5 decoded.active_agent_count;
  Alcotest.(check int) "pending_task_count" 3 decoded.pending_task_count
;;

let test_subscribe_request_roundtrip () =
  let req =
    T.SubscribeRequest.
      { agent_name = "test"
      ; session_id = "s1"
      ; event_types = [ "message"; "task" ]
      ; since_seq = 100L
      ; auth_token = "subscribe-token"
      }
  in
  let bytes = Masc_grpc_types.SubscribeRequest_serde.to_bytes req in
  let decoded = T.SubscribeRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" "test" decoded.agent_name;
  Alcotest.(check (list string)) "event_types" [ "message"; "task" ] decoded.event_types;
  Alcotest.(check int64) "since_seq" 100L decoded.since_seq
  ; Alcotest.(check string) "auth_token" "subscribe-token" decoded.auth_token
;;

let test_event_roundtrip () =
  let event =
    T.Event.
      { seq = 42L
      ; event_type = "broadcast"
      ; source_agent = "claude"
      ; timestamp_ms = 1700000000000L
      ; payload_json = {|{"text":"hello"}|}
      }
  in
  let bytes = T.Event.to_bytes event in
  let decoded = T.Event.of_bytes bytes in
  Alcotest.(check int64) "seq" 42L decoded.seq;
  Alcotest.(check string) "event_type" "broadcast" decoded.event_type;
  Alcotest.(check string) "source_agent" "claude" decoded.source_agent;
  Alcotest.(check int64) "timestamp_ms" 1700000000000L decoded.timestamp_ms;
  Alcotest.(check string) "payload_json" {|{"text":"hello"}|} decoded.payload_json
;;

let test_tool_call_request_roundtrip () =
  let req =
    T.ToolCallRequest.
      { agent_name = "test"
      ; session_id = "s1"
      ; tool_name = "masc_status"
      ; arguments_json = "{}"
      ; auth_token = "tool-token"
      }
  in
  let bytes = T.ToolCallRequest.to_bytes req in
  let decoded = T.ToolCallRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" "test" decoded.agent_name;
  Alcotest.(check string) "tool_name" "masc_status" decoded.tool_name;
  Alcotest.(check string) "arguments_json" "{}" decoded.arguments_json
  ; Alcotest.(check string) "auth_token" "tool-token" decoded.auth_token
;;

let test_tool_call_response_roundtrip () =
  let resp =
    T.ToolCallResponse.
      { success = true
      ; result_json = {|{"status":"ok"}|}
      ; error_message = ""
      ; error_code = 0
      }
  in
  let bytes = T.ToolCallResponse.to_bytes resp in
  let decoded = T.ToolCallResponse.of_bytes bytes in
  Alcotest.(check bool) "success" true decoded.success;
  Alcotest.(check string) "result_json" {|{"status":"ok"}|} decoded.result_json;
  Alcotest.(check string) "error_message" "" decoded.error_message;
  Alcotest.(check int) "error_code" 0 decoded.error_code
;;

let test_status_response_roundtrip () =
  let resp =
    T.StatusResponse.
      { agents =
          [ { T.name = "a1"
            ; status = "active"
            ; capabilities = []
            ; last_seen_ms = 0L
            ; session_bound_at_ms = 0L
            ; current_task_id = ""
            }
          ]
      ; tasks =
          [ { T.id = "t1"
            ; title = "Fix bug"
            ; status = "claimed"
            ; assigned_to = "a1"
            ; priority = 2
            }
          ]
      ; message_count = 10
      ; workspace_path = "/tmp/test"
      }
  in
  let bytes = T.StatusResponse.to_bytes resp in
  let decoded = T.StatusResponse.of_bytes bytes in
  Alcotest.(check int) "message_count" 10 decoded.message_count;
  Alcotest.(check string) "workspace_path" "/tmp/test" decoded.workspace_path;
  Alcotest.(check int) "agents count" 1 (List.length decoded.agents);
  Alcotest.(check int) "tasks count" 1 (List.length decoded.tasks);
  let task = List.hd decoded.tasks in
  Alcotest.(check string) "task title" "Fix bug" task.T.title;
  Alcotest.(check string) "task assigned_to" "a1" task.T.assigned_to;
  Alcotest.(check int) "task priority" 2 task.T.priority
;;

(* ====== Service construction test ====== *)

let test_service_name () =
  Alcotest.(check string)
    "service name"
    "masc.workspace.v1.MascWorkspace"
    Masc_grpc_service.service_name
;;

(* ====== gRPC server config tests ====== *)

let test_grpc_default_port () =
  Alcotest.(check int) "default port" 8936 Masc_grpc_server.default_port
;;

let test_grpc_stream_max_buffer_default () =
  (* Without the env override, the drop threshold defaults to 48 —
     the value below the 64-slot Grpc_eio.Stream capacity.  Clear any
     inherited value from the test harness so the default applies. *)
  let was_set = Sys.getenv_opt "MASC_GRPC_STREAM_MAX_BUFFER" in
  Unix.putenv "MASC_GRPC_STREAM_MAX_BUFFER" "";
  Fun.protect
    ~finally:(fun () ->
      match was_set with
      | Some v -> Unix.putenv "MASC_GRPC_STREAM_MAX_BUFFER" v
      | None -> Unix.putenv "MASC_GRPC_STREAM_MAX_BUFFER" "")
    (fun () ->
       Alcotest.(check int)
         "default is 48"
         48
         (Masc_grpc_service.stream_max_buffer ()))
;;

let test_grpc_stream_max_buffer_env_override () =
  (* Operators retune the drop threshold without a code change. *)
  let was_set = Sys.getenv_opt "MASC_GRPC_STREAM_MAX_BUFFER" in
  Unix.putenv "MASC_GRPC_STREAM_MAX_BUFFER" "12";
  Fun.protect
    ~finally:(fun () ->
      match was_set with
      | Some v -> Unix.putenv "MASC_GRPC_STREAM_MAX_BUFFER" v
      | None -> Unix.putenv "MASC_GRPC_STREAM_MAX_BUFFER" "")
    (fun () ->
       Alcotest.(check int)
         "env override applied"
         12
         (Masc_grpc_service.stream_max_buffer ()))
;;

let test_grpc_unary_timeout_is_finite_and_configurable () =
  let was_set = Sys.getenv_opt "MASC_GRPC_UNARY_TIMEOUT_SEC" in
  Fun.protect
    ~finally:(fun () ->
      match was_set with
      | Some value -> Unix.putenv "MASC_GRPC_UNARY_TIMEOUT_SEC" value
      | None -> Unix.putenv "MASC_GRPC_UNARY_TIMEOUT_SEC" "")
    (fun () ->
      Unix.putenv "MASC_GRPC_UNARY_TIMEOUT_SEC" "";
      Alcotest.(check (float 0.001))
        "default unary deadline"
        30.0
        (Env_config.Transport.grpc_unary_timeout_sec ());
      Unix.putenv "MASC_GRPC_UNARY_TIMEOUT_SEC" "17.5";
      Alcotest.(check (float 0.001))
        "configured unary deadline"
        17.5
        (Env_config.Transport.grpc_unary_timeout_sec ());
      Unix.putenv "MASC_GRPC_UNARY_TIMEOUT_SEC" "0";
      Alcotest.(check (float 0.001))
        "zero cannot disable unary deadline"
        30.0
        (Env_config.Transport.grpc_unary_timeout_sec ()))
;;

let test_grpc_opt_in_enablement () =
  (* With no valid MASC_GRPC_ENABLED value, experimental gRPC stays off. *)
  let was_set = Sys.getenv_opt "MASC_GRPC_ENABLED" in
  (match was_set with
   | Some _ -> Unix.putenv "MASC_GRPC_ENABLED" ""
   | None -> ());
  let result = Masc_grpc_server.is_enabled () in
  Alcotest.(check bool) "disabled by default" false result;
  (* Verify explicit enable still works. *)
  Unix.putenv "MASC_GRPC_ENABLED" "1";
  let enabled = Masc_grpc_server.is_enabled () in
  Alcotest.(check bool) "enabled via env" true enabled;
  (* Verify explicit disable still works. *)
  Unix.putenv "MASC_GRPC_ENABLED" "0";
  let disabled = Masc_grpc_server.is_enabled () in
  Alcotest.(check bool) "disabled via env" false disabled;
  (* Restore *)
  match was_set with
  | Some v -> Unix.putenv "MASC_GRPC_ENABLED" v
  | None -> ()
;;

let test_grpc_server_registers_health_service () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-grpc-health" (fun dir ->
      let workspace_config = Workspace_utils.default_config dir in
      let server =
        Masc_grpc_server.create_server
             ~port:Masc_grpc_server.default_port
             ~workspace_config
             ~tool_dispatcher:(fun ~identity:_ ~auth_token:_ ~tool_name:_ ~arguments:_ ->
               Ok "{}")
         in
         let services = Grpc_eio.Server.list_services server in
         Alcotest.(check bool)
           "server adds no implicit overall stream deadline"
           true
           (Option.is_none (Grpc_eio.Server.config server).default_timeout);
         Alcotest.(check bool)
           "workspace service registered"
           true
           (List.mem Masc_grpc_service.service_name services);
         Alcotest.(check bool)
           "reflection v1 service registered"
           true
           (List.mem "grpc.reflection.v1.ServerReflection" services);
         Alcotest.(check bool)
           "reflection v1alpha service registered"
           true
           (List.mem "grpc.reflection.v1alpha.ServerReflection" services);
         Alcotest.(check bool)
           "health service registered"
           true
         (List.mem "grpc.health.v1.Health" services))
;;

let test_get_status_projects_backlog_tasks () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-grpc-status" (fun dir ->
    let workspace_config = Workspace_utils.default_config dir in
    ignore (Masc.Workspace.init workspace_config ~agent_name:(Some "alpha"));
    ignore
      (Masc.Workspace.add_task
         workspace_config
         ~title:"Fix stale projection"
         ~priority:1
         ~description:"Use backlog SSOT for gRPC status");
    ignore (Masc.Workspace.claim_next workspace_config ~agent_name:"alpha");
    let token = create_worker_token dir "status-reader" in
    let service =
      Masc_grpc_service.create_service
        ~workspace_config
        ~tool_dispatcher:(fun ~identity:_ ~auth_token:_ ~tool_name:_ ~arguments:_ ->
          Ok "{}")
    in
    match Grpc_eio.Service.get_method service "GetStatus" with
    | Some { handler = `Unary handler; _ } ->
      let request = T.StatusRequest.to_bytes { auth_token = token } in
      let resp = T.StatusResponse.of_bytes (handler request) in
      Alcotest.(check int) "tasks count" 1 (List.length resp.tasks);
      let task = List.hd resp.tasks in
      Alcotest.(check string) "task id" "task-001" task.T.id;
      Alcotest.(check string) "task title" "Fix stale projection" task.T.title;
      Alcotest.(check string) "task status" "claimed" task.T.status;
      Alcotest.(check string) "task assignee" "alpha" task.T.assigned_to;
      Alcotest.(check int) "task priority" 1 task.T.priority;
      Alcotest.(check int)
        "message count comes from workspace SSOT"
        (List.length (Masc.Workspace.get_all_messages_raw workspace_config ~since_seq:0))
        resp.message_count;
      let persisted_agent =
        Masc.Workspace.get_all_agents workspace_config
        |> List.find (fun (agent : Masc_domain.agent) -> String.equal agent.name "alpha")
      in
      let projected_agent =
        List.find (fun (agent : T.agent_info) -> String.equal agent.name "alpha") resp.agents
      in
      let persisted_ms value =
        Masc_domain.parse_iso8601_opt value
        |> Option.map (fun seconds -> Int64.of_float (seconds *. 1000.0))
        |> Option.value ~default:0L
      in
      Alcotest.(check int64)
        "last_seen comes from persisted agent state"
        (persisted_ms persisted_agent.last_seen)
        projected_agent.last_seen_ms;
      Alcotest.(check int64)
        "session binding comes from persisted agent state"
        (persisted_ms persisted_agent.session_bound_at)
        projected_agent.session_bound_at_ms
    | _ -> Alcotest.fail "GetStatus unary handler missing")
;;

let test_empty_request_handling () =
  (* Verify graceful handling of empty protobuf message (all defaults). *)
  let bytes =
    T.ToolCallRequest.to_bytes
      { agent_name = ""
      ; session_id = ""
      ; tool_name = ""
      ; arguments_json = ""
      ; auth_token = ""
      }
  in
  let req = T.ToolCallRequest.of_bytes bytes in
  Alcotest.(check string) "empty agent_name" "" req.agent_name;
  Alcotest.(check string) "empty tool_name" "" req.tool_name
;;

let test_protobuf_binary_format () =
  (* Verify that serialized output is protobuf binary, not JSON. *)
  let req =
    T.ToolCallRequest.
      { agent_name = "test"
      ; session_id = "grpc-test"
      ; tool_name = "masc_status"
      ; arguments_json = "{}"
      ; auth_token = "tool-token"
      }
  in
  let bytes = T.ToolCallRequest.to_bytes req in
  (* Protobuf binary does not start with '{' like JSON. *)
  Alcotest.(check bool) "not JSON" true (String.length bytes = 0 || bytes.[0] <> '{')
;;

(* These tests verify two things:
   1. The error message starts with "protobuf decode error:" so log
      aggregators that bucket on this prefix keep working.
   2. The message embeds the *specific protobuf type name* that failed
      to decode, so operators can identify the wire boundary without
      reading the stack trace. The type_name parameter on
      [Masc_grpc_types.decode_result] makes this an enforced contract. *)
let test_subscribe_request_invalid_bytes_result () =
  match T.SubscribeRequest.of_bytes_result malformed_protobuf with
  | Ok _ -> Alcotest.fail "expected decode failure"
  | Error msg ->
    Alcotest.(check bool)
      "error keeps 'protobuf decode error:' prefix"
      true
      (String.starts_with ~prefix:"protobuf decode error:" msg);
    Alcotest.(check bool)
      "error names the failing protobuf type (SubscribeRequest)"
      true
      (String_util.contains_substring msg"SubscribeRequest")
;;

let test_tool_call_request_invalid_bytes_result () =
  match T.ToolCallRequest.of_bytes_result malformed_protobuf with
  | Ok _ -> Alcotest.fail "expected decode failure"
  | Error msg ->
    Alcotest.(check bool)
      "error keeps 'protobuf decode error:' prefix"
      true
      (String.starts_with ~prefix:"protobuf decode error:" msg);
    Alcotest.(check bool)
      "error names the failing protobuf type (ToolCallRequest)"
      true
      (String_util.contains_substring msg"ToolCallRequest")
;;

let test_tool_call_handler_invalid_bytes_raise_grpc_status () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-grpc-invalid-tool-call" (fun dir ->
    let workspace_config = Workspace_utils.default_config dir in
    let service =
      Masc_grpc_service.create_service
        ~workspace_config
        ~tool_dispatcher:(fun ~identity:_ ~auth_token:_ ~tool_name:_ ~arguments:_ ->
          Ok "{}")
    in
    match Grpc_eio.Service.get_method service "ToolCall" with
    | Some { handler = `Unary handler; _ } ->
      (match handler malformed_protobuf with
       | _ -> Alcotest.fail "expected typed gRPC decode error"
       | exception exn ->
         Alcotest.(check bool)
           "invalid_argument grpc error"
           true
           (String.starts_with
              ~prefix:"Grpc_error(INVALID_ARGUMENT:"
              (Printexc.to_string exn)))
    | _ -> Alcotest.fail "ToolCall unary handler missing")
;;

let test_subscribe_handler_invalid_bytes_raise_grpc_status () =
  with_temp_dir "masc-grpc-invalid-subscribe" (fun dir ->
    let workspace_config = Workspace_utils.default_config dir in
    let service =
      Masc_grpc_service.create_service
        ~workspace_config
        ~tool_dispatcher:(fun ~identity:_ ~auth_token:_ ~tool_name:_ ~arguments:_ ->
          Ok "{}")
    in
    match Grpc_eio.Service.get_method service "Subscribe" with
    | Some { handler = `ServerStreaming handler; _ } ->
      (match handler malformed_protobuf with
       | _ -> Alcotest.fail "expected typed gRPC decode error"
       | exception exn ->
         Alcotest.(check bool)
           "invalid_argument grpc error"
           true
           (String.starts_with
              ~prefix:"Grpc_error(INVALID_ARGUMENT:"
              (Printexc.to_string exn)))
    | _ -> Alcotest.fail "Subscribe server-streaming handler missing")
;;

let test_heartbeat_handler_invalid_bytes_closes_without_ack () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-grpc-invalid-heartbeat" (fun dir ->
    let workspace_config = Workspace_utils.default_config dir in
    let service =
      Masc_grpc_service.create_service
        ~workspace_config
        ~tool_dispatcher:(fun ~identity:_ ~auth_token:_ ~tool_name:_ ~arguments:_ ->
          Ok "{}")
    in
    match Grpc_eio.Service.get_method service "Heartbeat" with
    | Some { handler = `Bidi handler; _ } ->
      let baseline = latest_log_seq () in
      Eio.Switch.run
      @@ fun sw ->
      let request_stream = Grpc_eio.Stream.create 16 in
      let response_stream = handler ~sw request_stream in
      Grpc_eio.Stream.add request_stream malformed_protobuf;
      (match
         Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 1.0 (fun () ->
           Grpc_eio.Stream.take response_stream)
       with
       | _ -> Alcotest.fail "malformed Heartbeat produced an ack"
       | exception End_of_file -> ());
      let logs =
        Log.Ring.recent ~limit:20 ~module_filter:"Transport" ~since_seq:baseline ()
      in
      Alcotest.(check bool)
        "decode failure is observed"
        true
        (List.exists
           (fun (entry : Log.Ring.entry) ->
              entry.level = Log.Warn
              && String.starts_with ~prefix:"gRPC Heartbeat decode failed:" entry.message)
           logs);
      Alcotest.(check bool)
        "terminal stream failure is observed"
        true
        (List.exists
           (fun (entry : Log.Ring.entry) ->
              String.starts_with
                ~prefix:
                  "gRPC heartbeat fiber died outside iteration: Grpc_error(INVALID_ARGUMENT:"
                entry.message)
           logs);
      Grpc_eio.Stream.close request_stream
    | _ -> Alcotest.fail "Heartbeat bidi handler missing")
;;

let test_protected_methods_enforce_bearer_admission () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-grpc-tokenless" (fun dir ->
    let workspace_config = Workspace_utils.default_config dir in
    let tool_dispatches = ref 0 in
    let service =
      Masc_grpc_service.create_service
        ~workspace_config
        ~tool_dispatcher:(fun ~identity:_ ~auth_token:_ ~tool_name:_ ~arguments:_ ->
          incr tool_dispatches;
          Ok "{}")
    in
    let unary_reject method_name expected label request =
      match Grpc_eio.Service.get_method service method_name with
      | Some { handler = `Unary handler; _ } ->
        expect_grpc_status label expected (fun () -> handler request)
      | _ -> Alcotest.failf "%s unary handler missing" method_name
    in
    unary_reject
      "GetStatus"
      Grpc_core.Status.Unauthenticated
      "GetStatus tokenless"
      (T.StatusRequest.to_bytes { auth_token = "" });
    unary_reject
      "Broadcast"
      Grpc_core.Status.Unauthenticated
      "Broadcast tokenless"
      (T.BroadcastRequest.to_bytes
         { agent_name = "test-agent"
         ; message = "must not publish"
         ; mentions = []
         ; auth_token = ""
         });
    unary_reject
      "ToolCall"
      Grpc_core.Status.Unauthenticated
      "ToolCall tokenless"
      (T.ToolCallRequest.to_bytes
         { agent_name = "test-agent"
         ; session_id = "session-1"
         ; tool_name = "masc_status"
         ; arguments_json = "{}"
         ; auth_token = ""
         });
    let worker_token = create_worker_token dir "test-agent" in
    unary_reject
      "ToolCall"
      Grpc_core.Status.Unauthenticated
      "ToolCall actor mismatch"
      (T.ToolCallRequest.to_bytes
         { agent_name = "different-agent"
         ; session_id = "session-1"
         ; tool_name = "masc_status"
         ; arguments_json = "{}"
         ; auth_token = worker_token
         });
    Alcotest.(check int) "rejected tool requests are not dispatched" 0 !tool_dispatches;
    (match Grpc_eio.Service.get_method service "Subscribe" with
     | Some { handler = `ServerStreaming handler; _ } ->
       expect_grpc_status
         "Subscribe tokenless"
         Grpc_core.Status.Unauthenticated
         (fun () ->
            handler
              (T.SubscribeRequest_serde.to_bytes
                 { agent_name = "test-agent"
                 ; session_id = "session-1"
                 ; event_types = []
                 ; since_seq = 0L
                 ; auth_token = ""
                 }))
     | _ -> Alcotest.fail "Subscribe server-streaming handler missing");
    (match Grpc_eio.Service.get_method service "Heartbeat" with
     | Some { handler = `Bidi handler; _ } ->
       Eio.Switch.run
       @@ fun sw ->
       let requests = Grpc_eio.Stream.create 2 in
       let responses = handler ~sw requests in
       Grpc_eio.Stream.add
         requests
         (T.HeartbeatPing.to_bytes
            { agent_name = "test-agent"
            ; session_id = "session-1"
            ; timestamp_ms = 1L
            ; current_task_id = ""
            ; auth_token = ""
            });
       (match
          Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 1.0 (fun () ->
            Grpc_eio.Stream.take responses)
        with
        | _ -> Alcotest.fail "Heartbeat tokenless request produced an ack"
        | exception End_of_file -> ()
        | exception exn ->
          Alcotest.failf
            "Heartbeat tokenless rejection raised %s"
            (Printexc.to_string exn))
     | _ -> Alcotest.fail "Heartbeat bidi handler missing"))
;;

let test_tool_call_malformed_arguments_raise_invalid_argument () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-grpc-invalid-arguments" (fun dir ->
    let workspace_config = Workspace_utils.default_config dir in
    let token = create_worker_token dir "test-agent" in
    let dispatched = ref false in
    let service =
      Masc_grpc_service.create_service
        ~workspace_config
        ~tool_dispatcher:(fun ~identity:_ ~auth_token:_ ~tool_name:_ ~arguments:_ ->
          dispatched := true;
          Ok "{}")
    in
    match Grpc_eio.Service.get_method service "ToolCall" with
    | Some { handler = `Unary handler; _ } ->
      expect_grpc_status
        "malformed arguments_json"
        Grpc_core.Status.Invalid_argument
        (fun () ->
           handler
             (T.ToolCallRequest.to_bytes
                { agent_name = "test-agent"
                ; session_id = "session-1"
                ; tool_name = "masc_status"
                ; arguments_json = "{"
                ; auth_token = token
                }));
      Alcotest.(check bool) "dispatcher not called" false !dispatched
    | _ -> Alcotest.fail "ToolCall unary handler missing")
;;

(* ====== Test suite ====== *)

let () =
  Alcotest.run
    "masc_grpc_workspace"
    [ ( "types_roundtrip"
      , [ Alcotest.test_case
            "SubscribeRequest filtered"
            `Quick
            test_subscribe_filter_request_roundtrip
        ; Alcotest.test_case
            "ToolCallRequest dispatch"
            `Quick
            test_tool_call_dispatch_request_roundtrip
        ; Alcotest.test_case
            "StatusResponse agents"
            `Quick
            test_status_agents_response_roundtrip
        ; Alcotest.test_case "BroadcastRequest" `Quick test_broadcast_request_roundtrip
        ; Alcotest.test_case "BroadcastResponse" `Quick test_broadcast_response_roundtrip
        ; Alcotest.test_case "HeartbeatPing" `Quick test_heartbeat_ping_roundtrip
        ; Alcotest.test_case "HeartbeatAck" `Quick test_heartbeat_ack_roundtrip
        ; Alcotest.test_case "SubscribeRequest" `Quick test_subscribe_request_roundtrip
        ; Alcotest.test_case "Event" `Quick test_event_roundtrip
        ; Alcotest.test_case "ToolCallRequest" `Quick test_tool_call_request_roundtrip
        ; Alcotest.test_case "ToolCallResponse" `Quick test_tool_call_response_roundtrip
        ; Alcotest.test_case "StatusResponse" `Quick test_status_response_roundtrip
        ; Alcotest.test_case "empty_request" `Quick test_empty_request_handling
        ; Alcotest.test_case "protobuf_binary" `Quick test_protobuf_binary_format
        ; Alcotest.test_case
            "SubscribeRequest invalid bytes result"
            `Quick
            test_subscribe_request_invalid_bytes_result
        ; Alcotest.test_case
            "ToolCallRequest invalid bytes result"
            `Quick
            test_tool_call_request_invalid_bytes_result
        ] )
    ; ( "service"
      , [ Alcotest.test_case "service_name" `Quick test_service_name
        ; Alcotest.test_case
            "get_status_projects_backlog_tasks"
            `Quick
            test_get_status_projects_backlog_tasks
        ; Alcotest.test_case
            "tool call invalid bytes raise grpc status"
            `Quick
            test_tool_call_handler_invalid_bytes_raise_grpc_status
        ; Alcotest.test_case
            "subscribe invalid bytes raise grpc status"
            `Quick
            test_subscribe_handler_invalid_bytes_raise_grpc_status
        ; Alcotest.test_case
            "heartbeat invalid bytes close without ack"
            `Quick
            test_heartbeat_handler_invalid_bytes_closes_without_ack
        ; Alcotest.test_case
            "protected methods enforce bearer admission"
            `Quick
            test_protected_methods_enforce_bearer_admission
        ; Alcotest.test_case
            "tool call malformed arguments raise invalid_argument"
            `Quick
            test_tool_call_malformed_arguments_raise_invalid_argument
        ] )
    ; ( "server_config"
      , [ Alcotest.test_case "default_port" `Quick test_grpc_default_port
        ; Alcotest.test_case
            "opt_in_enablement"
            `Quick
            test_grpc_opt_in_enablement
        ; Alcotest.test_case
            "stream_max_buffer default"
            `Quick
            test_grpc_stream_max_buffer_default
        ; Alcotest.test_case
            "stream_max_buffer env override"
            `Quick
            test_grpc_stream_max_buffer_env_override
        ; Alcotest.test_case
            "unary timeout is finite and configurable"
            `Quick
            test_grpc_unary_timeout_is_finite_and_configurable
        ; Alcotest.test_case
            "registers_health_service"
            `Quick
            test_grpc_server_registers_health_service
        ] )
    ]
;;
