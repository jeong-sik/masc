(** Tests for MASC gRPC Workspace Service.

    Tests the types, service construction, and handler logic without
    requiring a running gRPC server or network connections.

    Wire format: protobuf binary (not JSON). Tests verify roundtrip
    serialization/deserialization via of_bytes/to_bytes. *)

module T = Masc_grpc_types
module Keeper_directive = Masc.Keeper_directive
module Keeper_registry = Masc.Keeper_registry

let keeper_meta ~name ~agent_name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String ("trace-" ^ name)
        ])
  with
  | Ok meta -> meta
  | Error error -> Alcotest.failf "invalid keeper meta fixture: %s" error
;;

let task_id value =
  match Keeper_id.Task_id.of_string value with
  | Ok task_id -> task_id
  | Error error -> Alcotest.failf "invalid test task id %S: %s" value error
;;

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

(* ====== Type serialization/deserialization round-trip tests ====== *)

(* The wire is a oneof now (#29396 A6), so these assertions read the arm
   rather than a string the codec used to build. The label is this suite's
   own: it exists to keep the expectations readable, not to reintroduce a
   string form the product parses. *)
let directive_label directive =
  match T.HeartbeatAck.directive_to_wire directive with
  | `Pause _ -> "pause"
  | `Wakeup _ -> "wakeup"
  | `Claim_task_id id -> "claim:" ^ id
  | `not_set -> "<not set>"
;;

let test_subscribe_filter_request_roundtrip () =
  let req =
    T.SubscribeRequest.
      { agent_name = "claude-swift-fox"
      ; session_id = "grpc-session-001"
      ; event_types = [ "task"; "message"; "agent.session_bound" ]
      ; since_seq = 42L
      }
  in
  let bytes = T.SubscribeRequest_serde.to_bytes req in
  let decoded = T.SubscribeRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" req.agent_name decoded.agent_name;
  Alcotest.(check string) "session_id" req.session_id decoded.session_id;
  Alcotest.(check (list string)) "event_types" req.event_types decoded.event_types;
  Alcotest.(check int64) "since_seq" req.since_seq decoded.since_seq
;;

let test_tool_call_dispatch_request_roundtrip () =
  let req =
    T.ToolCallRequest.
      { agent_name = "gemini-bright-owl"
      ; session_id = "grpc-gemini-12345"
      ; tool_name = "masc_status"
      ; arguments_json = {|{"_agent_name":"gemini-bright-owl"}|}
      }
  in
  let bytes = T.ToolCallRequest.to_bytes req in
  let decoded = T.ToolCallRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" req.agent_name decoded.agent_name;
  Alcotest.(check string) "session_id" req.session_id decoded.session_id;
  Alcotest.(check string) "tool_name" req.tool_name decoded.tool_name;
  Alcotest.(check string) "arguments_json" req.arguments_json decoded.arguments_json
;;

let test_status_agents_response_roundtrip () =
  let resp =
    T.StatusResponse.
      { agents =
          [ { T.name = "claude-swift-fox"
            ; status = "active"
            ; capabilities = [ "code" ]
            ; last_heartbeat_ms = 1700000000000L
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
      }
  in
  let bytes = T.BroadcastRequest.to_bytes req in
  let decoded = T.BroadcastRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" req.agent_name decoded.agent_name;
  Alcotest.(check string) "message" req.message decoded.message;
  Alcotest.(check (list string)) "mentions" req.mentions decoded.mentions
;;

let test_broadcast_response_roundtrip () =
  let resp =
    T.BroadcastResponse.
      { success = true
      ; seq = 42L
      ; request_id = Some "wmsg-0123456789abcdef0123456789abcdef"
      ; delivery_status = Delivery_accepted
      ; delivery_reason = None
      ; workspace_persistence_status = Workspace_persisted
      ; retry_disposition = Retry_do_not_resend
      }
  in
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
      }
  in
  let bytes = T.HeartbeatPing.to_bytes ping in
  let decoded = T.HeartbeatPing.of_bytes bytes in
  Alcotest.(check string) "agent_name" "test-agent" decoded.agent_name;
  Alcotest.(check string) "session_id" "sess-1" decoded.session_id;
  Alcotest.(check int64) "timestamp_ms" 1700000000000L decoded.timestamp_ms;
  Alcotest.(check string) "current_task_id" "task-42" decoded.current_task_id
;;

let test_heartbeat_ack_roundtrip () =
  let ack =
    T.HeartbeatAck.
      { timestamp_ms = 1700000000001L
      ; active_agent_count = 5
      ; pending_task_count = 3
      ; directives =
          [ Keeper_directive.Wakeup
          ; Keeper_directive.Assign_task (task_id "task-42")
          ]
      }
  in
  let bytes = T.HeartbeatAck.to_bytes ack in
  let decoded = T.HeartbeatAck.of_bytes bytes in
  Alcotest.(check int64) "timestamp_ms" 1700000000001L decoded.timestamp_ms;
  Alcotest.(check int) "active_agent_count" 5 decoded.active_agent_count;
  Alcotest.(check int) "pending_task_count" 3 decoded.pending_task_count;
  Alcotest.(check (list string))
    "directives"
    [ "wakeup"; "claim:task-42" ]
    (List.map directive_label decoded.directives)
;;

let test_subscribe_request_roundtrip () =
  let req =
    T.SubscribeRequest.
      { agent_name = "test"
      ; session_id = "s1"
      ; event_types = [ "message"; "task" ]
      ; since_seq = 100L
      }
  in
  let bytes = Masc_grpc_types.SubscribeRequest_serde.to_bytes req in
  let decoded = T.SubscribeRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" "test" decoded.agent_name;
  Alcotest.(check (list string)) "event_types" [ "message"; "task" ] decoded.event_types;
  Alcotest.(check int64) "since_seq" 100L decoded.since_seq
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
      }
  in
  let bytes = T.ToolCallRequest.to_bytes req in
  let decoded = T.ToolCallRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" "test" decoded.agent_name;
  Alcotest.(check string) "tool_name" "masc_status" decoded.tool_name;
  Alcotest.(check string) "arguments_json" "{}" decoded.arguments_json
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
            ; last_heartbeat_ms = 0L
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

let test_grpc_default_on_enablement () =
  (* With no MASC_GRPC_ENABLED env var, gRPC stays off: nothing has ever
     subscribed to it, so it does not open a port to prove that again. Both
     explicit settings still decide. *)
  let was_set = Sys.getenv_opt "MASC_GRPC_ENABLED" in
  (match was_set with
   | Some _ -> Unix.putenv "MASC_GRPC_ENABLED" ""
   | None -> ());
  let result = Masc_grpc_server.is_enabled () in
  Alcotest.(check bool) "off by default" false result;
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
             ~tool_dispatcher:(fun _tool _payload -> Ok "{}")
         in
         let services = Grpc_eio.Server.list_services server in
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
    (* Registration turns the requested "alpha" into a generated nickname
       ("alpha-witty-gecko"), and claiming a task moves the agent off "active".
       Re-stating either literal here would pin the naming scheme and the
       status vocabulary instead of the projection, so both come from the
       workspace itself. *)
    let sole_agent () =
      match Masc.Workspace.get_agents_raw workspace_config with
      | [ (agent : Masc_domain.agent) ] -> agent
      | agents ->
        Alcotest.failf "expected exactly 1 registered agent, got %d" (List.length agents)
    in
    let agent_name = (sole_agent ()).name in
    ignore
      (Masc.Workspace.add_task
         workspace_config
         ~title:"Fix stale projection"
         ~priority:1
         ~description:"Use backlog SSOT for gRPC status");
    ignore (Masc.Workspace.claim_next_r workspace_config ~agent_name ());
    let service =
      Masc_grpc_service.create_service
        ~workspace_config
        ~tool_dispatcher:(fun _tool _payload -> Ok "{}")
    in
    match Grpc_eio.Service.get_method service "GetStatus" with
    | Some { handler = `Unary handler; _ } ->
      let resp = T.StatusResponse.of_bytes (handler "") in
      Alcotest.(check int) "agents count" 1 (List.length resp.agents);
      let agent = List.hd resp.agents in
      let stored = sole_agent () in
      Alcotest.(check string) "agent name" stored.name agent.T.name;
      Alcotest.(check string)
        "agent status"
        (Masc_domain.agent_status_to_string stored.status)
        agent.T.status;
      Alcotest.(check int) "tasks count" 1 (List.length resp.tasks);
      let task = List.hd resp.tasks in
      Alcotest.(check string) "task id" "task-001" task.T.id;
      Alcotest.(check string) "task title" "Fix stale projection" task.T.title;
      Alcotest.(check string) "task status" "claimed" task.T.status;
      Alcotest.(check string) "task assignee" stored.name task.T.assigned_to;
      Alcotest.(check int) "task priority" 1 task.T.priority
    | _ -> Alcotest.fail "GetStatus unary handler missing")
;;

let test_empty_request_handling () =
  (* Verify graceful handling of empty protobuf message (all defaults). *)
  let bytes =
    T.ToolCallRequest.to_bytes
      { agent_name = ""; session_id = ""; tool_name = ""; arguments_json = "" }
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
        ~tool_dispatcher:(fun _tool _payload -> Ok "{}")
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
        ~tool_dispatcher:(fun _tool _payload -> Ok "{}")
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

(* #30399. [since_seq] says "resume from this sequence number" and this
   endpoint serves no backlog, so a resume it cannot honour is refused rather
   than answered with live events numbered as if the gap were not there. *)
let subscribe_bytes ~since_seq =
  Masc_grpc_types.SubscribeRequest_serde.to_bytes
    T.SubscribeRequest.
      { agent_name = "resume-probe"; session_id = "s1"; event_types = []; since_seq }
;;

let test_subscribe_refuses_a_resume_it_cannot_serve () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-grpc-subscribe-resume" (fun dir ->
    let workspace_config = Workspace_utils.default_config dir in
    let service =
      Masc_grpc_service.create_service
        ~workspace_config
        ~tool_dispatcher:(fun _tool _payload -> Ok "{}")
    in
    match Grpc_eio.Service.get_method service "Subscribe" with
    | Some { handler = `ServerStreaming handler; _ } ->
      (match handler (subscribe_bytes ~since_seq:100L) with
       | _ -> Alcotest.fail "a non-zero since_seq must not open a stream"
       | exception exn ->
         let text = Printexc.to_string exn in
         Alcotest.(check bool)
           "refused as UNIMPLEMENTED rather than served silently"
           true
           (String.starts_with ~prefix:"Grpc_error(UNIMPLEMENTED:" text);
         Alcotest.(check bool)
           "the refusal names the value it could not honour"
           true
           (String_util.contains_substring text "100"));
      (* Zero is "from now", which this endpoint does serve. *)
      (match handler (subscribe_bytes ~since_seq:0L) with
       | _stream -> ()
       | exception exn ->
         Alcotest.failf "since_seq=0 must still stream: %s" (Printexc.to_string exn))
    | _ -> Alcotest.fail "Subscribe server-streaming handler missing")
;;

let test_heartbeat_handler_invalid_bytes_warns_and_continues () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-grpc-invalid-heartbeat" (fun dir ->
    let workspace_config = Workspace_utils.default_config dir in
    let service =
      Masc_grpc_service.create_service
        ~workspace_config
        ~tool_dispatcher:(fun _tool _payload -> Ok "{}")
    in
    match Grpc_eio.Service.get_method service "Heartbeat" with
    | Some { handler = `Bidi handler; _ } ->
      let baseline = latest_log_seq () in
      Eio.Switch.run
      @@ fun sw ->
      let request_stream = Grpc_eio.Stream.create 16 in
      let response_stream = handler ~sw request_stream in
      Grpc_eio.Stream.add request_stream malformed_protobuf;
      Grpc_eio.Stream.add
        request_stream
        (T.HeartbeatPing.to_bytes
           { agent_name = "test-agent"
           ; session_id = "sess-1"
           ; timestamp_ms = 1700000000000L
           ; current_task_id = ""
           });
      let ack_bytes =
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 1.0 (fun () ->
          Grpc_eio.Stream.take response_stream)
      in
      let ack = T.HeartbeatAck.of_bytes ack_bytes in
      Alcotest.(check int) "active agents" 0 ack.active_agent_count;
      let logs =
        Log.Ring.recent ~limit:20 ~module_filter:"Transport" ~since_seq:baseline ()
      in
      Alcotest.(check bool)
        "decode failure logged as warn"
        true
        (List.exists
           (fun (entry : Log.Ring.entry) ->
              entry.level = Log.Warn
              && String.starts_with ~prefix:"gRPC Heartbeat decode failed:" entry.message)
           logs);
      Alcotest.(check bool)
        "decode failure not logged as crash"
        false
        (List.exists
           (fun (entry : Log.Ring.entry) ->
              String.starts_with ~prefix:"gRPC heartbeat iteration crashed:" entry.message)
           logs);
      Grpc_eio.Stream.close request_stream
    | _ -> Alcotest.fail "Heartbeat bidi handler missing")
;;

let test_heartbeat_projects_workspace_view () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-grpc-heartbeat-workspace-view" (fun dir ->
    let workspace_config = Workspace_utils.default_config dir in
    ignore (Masc.Workspace.init workspace_config ~agent_name:(Some "alpha"));
    ignore
      (Masc.Workspace.add_task
         workspace_config
         ~title:"Keep claimed work pending"
         ~priority:1
         ~description:"Project the Workspace task snapshot");
    ignore (Masc.Workspace.claim_next_r workspace_config ~agent_name:"alpha" ());
    let service =
      Masc_grpc_service.create_service
        ~workspace_config
        ~tool_dispatcher:(fun _tool _payload -> Ok "{}")
    in
    match Grpc_eio.Service.get_method service "Heartbeat" with
    | Some { handler = `Bidi handler; _ } ->
      Eio.Switch.run
      @@ fun sw ->
      let request_stream = Grpc_eio.Stream.create 16 in
      let response_stream = handler ~sw request_stream in
      Grpc_eio.Stream.add
        request_stream
        (T.HeartbeatPing.to_bytes
           { agent_name = "alpha"
           ; session_id = "sess-workspace-view"
           ; timestamp_ms = 1700000000000L
           ; current_task_id = ""
           });
      let ack =
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 1.0 (fun () ->
          Grpc_eio.Stream.take response_stream)
        |> T.HeartbeatAck.of_bytes
      in
      Alcotest.(check (list string))
        "claimed task emits no assignment directive"
        []
        (List.map directive_label ack.directives);
      Alcotest.(check int) "active agents" 1 ack.active_agent_count;
      Alcotest.(check int) "pending tasks" 1 ack.pending_task_count;
      Grpc_eio.Stream.close request_stream
    | _ -> Alcotest.fail "Heartbeat bidi handler missing")
;;

let test_heartbeat_projects_keeper_pause_not_workspace_pause () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Keeper_registry.For_testing.clear ();
  with_temp_dir "masc-grpc-heartbeat-keeper-pause" (fun dir ->
    Fun.protect
      ~finally:Keeper_registry.For_testing.clear
      (fun () ->
    let workspace_config = Workspace_utils.default_config dir in
    let agent_name = "alpha" in
    let keeper_name = "alpha" in
    ignore (Masc.Workspace.init workspace_config ~agent_name:(Some agent_name));
    let meta = keeper_meta ~name:keeper_name ~agent_name in
    ignore
      (Keeper_registry.For_testing.register
         ~base_path:workspace_config.base_path
         keeper_name
         meta);
    Masc.Workspace.pause workspace_config ~by:"operator" ~reason:"maintenance";
    let service =
      Masc_grpc_service.create_service
        ~workspace_config
        ~tool_dispatcher:(fun _tool _payload -> Ok "{}")
    in
    match Grpc_eio.Service.get_method service "Heartbeat" with
    | Some { handler = `Bidi handler; _ } ->
      Eio.Switch.run
      @@ fun sw ->
      let request_stream = Grpc_eio.Stream.create 16 in
      let response_stream = handler ~sw request_stream in
      let send_heartbeat session_id =
        Grpc_eio.Stream.add
          request_stream
          (T.HeartbeatPing.to_bytes
             { agent_name
             ; session_id
             ; timestamp_ms = 1700000000000L
             ; current_task_id = ""
             });
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 1.0 (fun () ->
          Grpc_eio.Stream.take response_stream)
        |> T.HeartbeatAck.of_bytes
      in
      let workspace_paused_ack = send_heartbeat "sess-workspace-pause" in
      Alcotest.(check (list string))
        "workspace pause does not become a durable keeper pause"
        []
        (List.map directive_label workspace_paused_ack.directives);
      ignore (Masc.Workspace.resume workspace_config ~by:"operator");
      ignore
        (Keeper_registry.For_testing.register
           ~base_path:workspace_config.base_path
           keeper_name
           { meta with paused = true });
      let keeper_paused_ack = send_heartbeat "sess-keeper-pause" in
      Alcotest.(check (list string))
        "durable keeper pause reaches its control stream"
        [ "pause" ]
        (List.map directive_label keeper_paused_ack.directives);
      Grpc_eio.Stream.close request_stream
    | _ -> Alcotest.fail "Heartbeat bidi handler missing"))
;;

let test_heartbeat_does_not_materialize_uninitialized_workspace () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Keeper_registry.For_testing.clear ();
  with_temp_dir "masc-grpc-heartbeat-uninitialized" (fun dir ->
    Fun.protect
      ~finally:Keeper_registry.For_testing.clear
      (fun () ->
    let workspace_config = Workspace_utils.default_config dir in
    let state_path = Workspace_utils.state_path workspace_config in
    Alcotest.(check bool) "state absent before heartbeat" false (Sys.file_exists state_path);
    let service =
      Masc_grpc_service.create_service
        ~workspace_config
        ~tool_dispatcher:(fun _tool _payload -> Ok "{}")
    in
    match Grpc_eio.Service.get_method service "Heartbeat" with
    | Some { handler = `Bidi handler; _ } ->
      Eio.Switch.run
      @@ fun sw ->
      let request_stream = Grpc_eio.Stream.create 16 in
      let response_stream = handler ~sw request_stream in
      Grpc_eio.Stream.add
        request_stream
        (T.HeartbeatPing.to_bytes
           { agent_name = "uninitialized-grpc-agent"
           ; session_id = "sess-uninitialized"
           ; timestamp_ms = 1700000000000L
           ; current_task_id = ""
           });
      let ack =
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 1.0 (fun () ->
          Grpc_eio.Stream.take response_stream)
        |> T.HeartbeatAck.of_bytes
      in
      Alcotest.(check (list string))
        "uninitialized heartbeat has no directives"
        []
        (List.map directive_label ack.directives);
      Alcotest.(check bool)
        "heartbeat leaves state absent"
        false
        (Sys.file_exists state_path);
      Grpc_eio.Stream.close request_stream
    | _ -> Alcotest.fail "Heartbeat bidi handler missing"))
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
            "subscribe refuses a resume it cannot serve"
            `Quick
            test_subscribe_refuses_a_resume_it_cannot_serve
        ; Alcotest.test_case
            "heartbeat invalid bytes warn and continue"
            `Quick
            test_heartbeat_handler_invalid_bytes_warns_and_continues
        ; Alcotest.test_case
            "heartbeat projects workspace view"
            `Quick
            test_heartbeat_projects_workspace_view
        ; Alcotest.test_case
            "heartbeat projects keeper pause only"
            `Quick
            test_heartbeat_projects_keeper_pause_not_workspace_pause
        ; Alcotest.test_case
            "heartbeat leaves uninitialized workspace absent"
            `Quick
            test_heartbeat_does_not_materialize_uninitialized_workspace
        ] )
    ; ( "server_config"
      , [ Alcotest.test_case "default_port" `Quick test_grpc_default_port
        ; Alcotest.test_case
            "default_on_enablement"
            `Quick
            test_grpc_default_on_enablement
        ; Alcotest.test_case
            "stream_max_buffer default"
            `Quick
            test_grpc_stream_max_buffer_default
        ; Alcotest.test_case
            "stream_max_buffer env override"
            `Quick
            test_grpc_stream_max_buffer_env_override
        ; Alcotest.test_case
            "registers_health_service"
            `Quick
            test_grpc_server_registers_health_service
        ] )
    ]
;;
