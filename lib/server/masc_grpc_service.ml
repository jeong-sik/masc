(** MASC gRPC Workspace Service.

    Implements the MascWorkspace gRPC service using grpc-direct.
    All handlers delegate to the Workspace module for actual workspace logic.

    Wire format: protobuf binary via ocaml-protoc-plugin.
    See proto/masc_workspace.proto for the canonical API contract. *)

module T = Masc_grpc_types

(** Service name matching the proto package.service pattern. *)
let service_name = "masc.workspace.v1.MascWorkspace"

(** Current timestamp in milliseconds. *)
let now_ms () = Int64.of_float (Unix.gettimeofday () *. 1000.0)

(** Per-subscriber outbound buffer drop threshold.

    Reads [MASC_GRPC_STREAM_MAX_BUFFER] on each call so tests and
    operators can drive it without wiring in-process state.  The
    default 48 leaves headroom under the 64-slot stream capacity; a
    value at or above stream capacity effectively disables the gate
    and lets Grpc_eio.Stream itself decide (usually the wrong
    choice, but available for debugging). *)
let stream_max_buffer () =
  Env_config_core.get_int ~default:48 "MASC_GRPC_STREAM_MAX_BUFFER"
;;

let decode_request_or_raise ~rpc decode bytes =
  match decode bytes with
  | Ok req -> req
  | Error msg ->
    Log.Transport.warn "gRPC %s decode failed: %s" rpc msg;
    Grpc_core.Status.raise_error
      Grpc_core.Status.Invalid_argument
      (Printf.sprintf "%s request decode failed: %s" rpc msg)
;;

let grpc_status_of_admission_error = function
  | Masc_domain.Auth (Masc_domain.Auth_error.Forbidden _) ->
    Grpc_core.Status.Permission_denied, "Bearer role does not permit this RPC."
  | Masc_domain.Auth
      (Masc_domain.Auth_error.Unauthorized _
      | Masc_domain.Auth_error.TokenExpired _
      | Masc_domain.Auth_error.InvalidToken _) ->
    Grpc_core.Status.Unauthenticated, "Bearer authentication failed."
  | Masc_domain.Task _
  | Masc_domain.Agent _
  | Masc_domain.System _
  | Masc_domain.RateLimitExceeded _
  | Masc_domain.CacheError _ ->
    Grpc_core.Status.Internal, "Bearer admission failed internally."
;;

let authorize_or_raise ~workspace_config ~auth_token ~claimed_agent ~requirement =
  match
    Server_transport_admission.authorize
      ~base_path:workspace_config.Workspace_utils_backend_setup.base_path
      ~token:(Some auth_token)
      ~claimed_agent
      ~requirement
  with
  | Ok identity -> identity
  | Error err ->
    let code, message = grpc_status_of_admission_error err in
    Grpc_core.Status.raise_error code message
;;

let decode_tool_arguments_or_raise arguments_json =
  match Yojson.Safe.from_string arguments_json with
  | `Assoc _ as arguments -> arguments
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _
  | `String _
  | `List _
  | `Tuple _
  | `Variant _ ->
    Grpc_core.Status.raise_error
      Grpc_core.Status.Invalid_argument
      "ToolCall arguments_json must encode a JSON object."
  | exception Yojson.Json_error message ->
    Grpc_core.Status.raise_error
      Grpc_core.Status.Invalid_argument
      (Printf.sprintf "ToolCall arguments_json is malformed JSON: %s" message)
;;

let task_assignee_of_status status =
  match Masc_domain.task_assignee_of_status status with
  | Some a -> a
  | None -> ""
;;

let task_info_of_task (task : Masc_domain.task) : T.task_info =
  { T.id = task.id
  ; title = task.title
  ; status = Masc_domain.string_of_task_status task.task_status
  ; assigned_to = task_assignee_of_status task.task_status
  ; priority = task.priority
  }
;;

let persisted_timestamp_ms ~agent_name ~field value =
  match Masc_domain.parse_iso8601_opt value with
  | Some seconds -> Int64.of_float (seconds *. 1000.0)
  | None ->
    Log.Transport.warn
      "gRPC GetStatus: agent %s has invalid persisted %s timestamp: %S"
      agent_name
      field
      value;
    0L
;;

(** {1 Unary Handlers} *)

(** Broadcast handler: send a message to all agents. *)
let handle_broadcast (workspace_config : Workspace_utils_backend_setup.config) (bytes : string)
  : string
  =
  let req =
    decode_request_or_raise ~rpc:"Broadcast" T.BroadcastRequest.of_bytes_result bytes
  in
  let identity =
    authorize_or_raise
      ~workspace_config
      ~auth_token:req.auth_token
      ~claimed_agent:(Some req.agent_name)
      ~requirement:(Server_transport_admission.Permission Masc_domain.CanBroadcast)
  in
  let result =
    try
      let content =
        if req.mentions = []
        then req.message
        else (
          let mention_prefix =
            String.concat " " (List.map (fun m -> "@" ^ m) req.mentions)
          in
          mention_prefix ^ " " ^ req.message)
      in
      let _msg =
        Workspace.broadcast workspace_config ~from_agent:identity.agent_name ~content
      in
      T.BroadcastResponse.{ success = true; seq = now_ms () }
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Transport.error "gRPC broadcast failed: %s" (Printexc.to_string exn);
      T.BroadcastResponse.{ success = false; seq = 0L }
  in
  T.BroadcastResponse.to_bytes result
;;

(** GetStatus handler: return current workspace state. *)
let handle_get_status (workspace_config : Workspace_utils_backend_setup.config) (bytes : string)
  : string
  =
  let req =
    decode_request_or_raise ~rpc:"GetStatus" T.StatusRequest.of_bytes_result bytes
  in
  let _identity =
    authorize_or_raise
      ~workspace_config
      ~auth_token:req.auth_token
      ~claimed_agent:None
      ~requirement:(Server_transport_admission.Permission Masc_domain.CanReadState)
  in
  let agents =
    Workspace.get_all_agents workspace_config
    |> List.map (fun (agent : Masc_domain.agent) ->
      ({ T.name = agent.name
       ; status = Masc_domain.agent_status_to_string agent.status
       ; capabilities = agent.capabilities
       ; last_seen_ms =
           persisted_timestamp_ms
             ~agent_name:agent.name
             ~field:"last_seen"
             agent.last_seen
       ; session_bound_at_ms =
           persisted_timestamp_ms
             ~agent_name:agent.name
             ~field:"session_bound_at"
             agent.session_bound_at
       ; (* DET-OK: absent task is represented as no current task in the response. *)
         current_task_id = Option.value ~default:"" agent.current_task
       }
       : T.agent_info))
  in
  let tasks = Workspace.get_tasks_safe workspace_config |> List.map task_info_of_task in
  let message_count =
    Workspace.get_all_messages_raw workspace_config ~since_seq:0 |> List.length
  in
  T.StatusResponse.(
    to_bytes { agents; tasks; message_count; workspace_path = workspace_config.base_path })
;;

(** ToolCall handler: dispatch an MCP tool call via gRPC. *)
let handle_tool_call
      (workspace_config : Workspace_utils_backend_setup.config)
      (tool_dispatcher :
         identity:Server_transport_admission.identity
         -> auth_token:string
         -> tool_name:string
         -> arguments:Yojson.Safe.t
         -> (string, string) result)
      (bytes : string)
  : string
  =
  let req =
    decode_request_or_raise ~rpc:"ToolCall" T.ToolCallRequest.of_bytes_result bytes
  in
  let identity =
    authorize_or_raise
      ~workspace_config
      ~auth_token:req.auth_token
      ~claimed_agent:(Some req.agent_name)
      ~requirement:(Server_transport_admission.Tool req.tool_name)
  in
  let arguments = decode_tool_arguments_or_raise req.arguments_json in
  let result =
    match
      tool_dispatcher
        ~identity
        ~auth_token:req.auth_token
        ~tool_name:req.tool_name
        ~arguments
    with
    | Ok result_json ->
      T.ToolCallResponse.
        { success = true; result_json; error_message = ""; error_code = 0 }
    | Error msg ->
      T.ToolCallResponse.
        { success = false; result_json = ""; error_message = msg; error_code = Mcp_error_code.(to_wire_code Internal_error) }
  in
  T.ToolCallResponse.to_bytes result
;;

(** {1 Streaming Handlers} *)

(** Active heartbeat stream count (atomic for signal safety). *)
let active_heartbeat_streams = Atomic.make 0

(** Active subscribe stream count (atomic for signal safety). *)
let active_subscribe_streams = Atomic.make 0

(** Heartbeat bidi handler: receive pings, respond with acks. *)
let handle_heartbeat
      (workspace_config : Workspace_utils_backend_setup.config)
      ~(sw : Eio.Switch.t)
      (request_stream : string Grpc_eio.Stream.t)
  : string Grpc_eio.Stream.t
  =
  let response_stream = Grpc_eio.Stream.create 16 in
  Atomic.incr active_heartbeat_streams;
  Transport_metrics.set_grpc_active_streams (Atomic.get active_heartbeat_streams);
  Eio.Fiber.fork ~sw (fun () ->
    let cleanup () =
      Atomic.decr active_heartbeat_streams;
      Transport_metrics.set_grpc_active_streams (Atomic.get active_heartbeat_streams);
      (* Called from [End_of_file] at line 360 and the generic-[exn] handler
         at line 371 — neither is a cancel handler. [with _ -> ()] would
         swallow [Eio.Cancel.Cancelled] racing with [Stream.close], leaving
         the fiber to fall past the cancel boundary. The counters above are
         decremented first, so re-raising here is safe. *)
      try Grpc_eio.Stream.close response_stream with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Transport.warn
          "masc_grpc_service: stream close failed: %s"
          (Printexc.to_string exn)
    in
    let rec loop () =
      match Grpc_eio.Stream.take request_stream with
      | bytes ->
        let ping =
          decode_request_or_raise ~rpc:"Heartbeat" T.HeartbeatPing.of_bytes_result bytes
        in
           let identity =
             authorize_or_raise
               ~workspace_config
               ~auth_token:ping.auth_token
               ~claimed_agent:(Some ping.agent_name)
               ~requirement:(Server_transport_admission.Permission Masc_domain.CanReadState)
           in
           let agent_name = identity.agent_name in
           (try
              let t0 = Unix.gettimeofday () in
              (match Workspace.heartbeat_r workspace_config ~agent_name with
               | Workspace.Heartbeat_updated _ -> ()
               | Workspace.Heartbeat_agent_not_found { agent_name } ->
                 Grpc_core.Status.raise_error
                   Grpc_core.Status.Not_found
                   (Printf.sprintf
                      "Heartbeat credential owner %s has no bound workspace agent."
                      agent_name)
               | Workspace.Heartbeat_invalid_agent_file { agent_name; detail } ->
                 Grpc_core.Status.raise_error
                   Grpc_core.Status.Data_loss
                   (Printf.sprintf
                      "Heartbeat agent state for %s is invalid: %s"
                      agent_name
                      detail));
              let agent_count =
                Workspace.get_active_agents workspace_config |> List.length
              in
              let pending_count =
                Workspace.get_tasks_safe workspace_config
                |> List.fold_left
                     (fun count (task : Masc_domain.task) ->
                       match task.task_status with
                       | Masc_domain.Todo
                       | Masc_domain.Claimed _
                       | Masc_domain.InProgress _
                       | Masc_domain.AwaitingVerification _ ->
                         count + 1
                       | Masc_domain.Done _ | Masc_domain.Cancelled _ -> count)
                     0
              in
              let ack =
                T.HeartbeatAck.
                  { timestamp_ms = now_ms ()
                  ; active_agent_count = agent_count
                  ; pending_task_count = pending_count
                  }
              in
              let ack_bytes = T.HeartbeatAck.to_bytes ack in
              Transport_metrics.inc_grpc_bytes_sent ~bytes:(String.length ack_bytes);
              Grpc_eio.Stream.add response_stream ack_bytes;
              (* Record heartbeat latency *)
              let latency = Unix.gettimeofday () -. t0 in
              Transport_metrics.observe_grpc_heartbeat_latency latency
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Log.Transport.error
                "gRPC heartbeat iteration crashed: %s"
                (Printexc.to_string exn);
              raise exn);
        loop ()
      | exception End_of_file -> cleanup ()
    in
    try loop () with
    | Eio.Cancel.Cancelled _ as e ->
      cleanup ();
      raise e
    | exn ->
      Log.Transport.error
        "gRPC heartbeat fiber died outside iteration: %s"
        (Printexc.to_string exn);
      cleanup ());
  response_stream
;;

(** Subscribe server-streaming handler: push workspace events to the agent. *)
let handle_subscribe (workspace_config : Workspace_utils_backend_setup.config) (bytes : string)
  : string Grpc_eio.Stream.t
  =
  let req =
    decode_request_or_raise ~rpc:"Subscribe" T.SubscribeRequest.of_bytes_result bytes
  in
  let identity =
    authorize_or_raise
      ~workspace_config
      ~auth_token:req.auth_token
      ~claimed_agent:(Some req.agent_name)
      ~requirement:(Server_transport_admission.Permission Masc_domain.CanReadState)
  in
  let stream = Grpc_eio.Stream.create 64 in
  Atomic.incr active_subscribe_streams;
  Transport_metrics.set_grpc_subscribers (Atomic.get active_subscribe_streams);
  let events_count = ref 0 in
  let stream_closed = Atomic.make false in
  let sub_id = Printf.sprintf "grpc-subscribe-%s-%Ld" identity.agent_name (now_ms ()) in
  let cleanup_subscriber ?exn () =
    if Atomic.compare_and_set stream_closed false true
    then (
      Sse.unsubscribe_external sub_id;
      Atomic.decr active_subscribe_streams;
      Transport_metrics.set_grpc_subscribers (Atomic.get active_subscribe_streams);
      Option.iter
        (fun err ->
           Log.Misc.warn "gRPC subscriber %s failed: %s" sub_id (Printexc.to_string err))
        exn;
      Log.Misc.info "gRPC subscriber %s cleaned up" sub_id)
  in
  (* Send initial event confirming subscription *)
  let init_event =
    T.Event.
      { seq = 0L
      ; event_type = "subscription_started"
      ; source_agent = "server"
      ; timestamp_ms = now_ms ()
      ; payload_json =
          Printf.sprintf
            {|{"agent_name":"%s","event_types":%s}|}
            identity.agent_name
            (Yojson.Safe.to_string
               (`List (List.map (fun s -> `String s) req.event_types)))
      }
  in
  let init_bytes = T.Event.to_bytes init_event in
  Transport_metrics.inc_grpc_bytes_sent ~bytes:(String.length init_bytes);
  Grpc_eio.Stream.add stream init_bytes;
  incr events_count;
  (* Read recent messages and push as events *)
  let backlog_file =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path:workspace_config.base_path)
      "backlog.jsonl"
  in
  if Sys.file_exists backlog_file
  then (
    let content = Fs_compat.load_file backlog_file in
    let lines = String.split_on_char '\n' content in
    let seq = ref 1L in
    let scanned = ref 0 in
    let replayed = ref 0 in
    List.iter
      (fun line ->
         if String.length line > 0
         then (
           incr scanned;
           let msg_seq = !seq in
           if Int64.compare msg_seq req.since_seq > 0
           then (
             let event =
               T.Event.
                 { seq = msg_seq
                 ; event_type = "message"
                 ; source_agent = ""
                 ; timestamp_ms = now_ms ()
                 ; payload_json = line
                 }
             in
             let event_bytes = T.Event.to_bytes event in
             Transport_metrics.inc_grpc_bytes_sent ~bytes:(String.length event_bytes);
             Grpc_eio.Stream.add stream event_bytes;
             incr events_count;
             incr replayed);
           seq := Int64.add !seq 1L))
      lines;
    (* Attribution: scanned vs replayed splits wasted scan cost from
       useful catch-up delivery on this Subscribe RPC. *)
    if !scanned > 0
    then Transport_metrics.inc_grpc_backlog_replay_lines_scanned ~delta:!scanned ();
    if !replayed > 0
    then Transport_metrics.inc_grpc_backlog_replay_events_replayed ~delta:!replayed ());
  (* Record delivered events from backlog replay *)
  Transport_metrics.inc_grpc_events_delivered ~delta:!events_count ();
  (* Hook into SSE broadcast mechanism for real-time event push.
     External subscriber receives formatted SSE event strings on every
     Sse.broadcast/broadcast_to call, converts them to gRPC Event messages,
     and pushes into the gRPC response stream.

     IMPORTANT: The callback runs synchronously inside broadcast_impl,
     so it MUST NOT block. We use Grpc_eio.Stream.length to check
     capacity before adding. If the stream is full or closed, the event
     is dropped and the subscriber auto-unregisters. *)
  let seq_counter = Atomic.make (Int64.to_int req.since_seq + 1) in
  (* Read once per subscribe so existing streams are not disturbed
     mid-flight by a config change; newly-subscribing clients pick up
     the new value. *)
  let max_buffer = stream_max_buffer () in
  Sse.subscribe_external
    ~id:sub_id
    ~is_alive:(fun () ->
      (not (Atomic.get stream_closed)) && not (Grpc_eio.Stream.is_closed stream))
    ~callback:(fun sse_event ->
      if Atomic.get stream_closed || Grpc_eio.Stream.is_closed stream
      then
        (* Stream already gone — auto-cleanup *)
        cleanup_subscriber ()
      else if Grpc_eio.Stream.length stream >= max_buffer
      then (
        (* Stream buffer near-full — drop event to avoid blocking broadcast.
         Bump [masc_grpc_events_dropped_total] so the capacity pressure
         is visible to operators and the drop is not just a log line. *)
        Transport_metrics.inc_grpc_events_dropped ();
        Log.Misc.warn
          "gRPC subscriber %s: buffer full (%d), dropping event"
          sub_id
          (Grpc_eio.Stream.length stream))
      else (
        let seq = Int64.of_int (Atomic.fetch_and_add seq_counter 1) in
        let event =
          T.Event.
            { seq
            ; event_type = "sse_broadcast"
            ; source_agent = "server"
            ; timestamp_ms = now_ms ()
            ; payload_json = sse_event
            }
        in
        try
          let event_bytes = T.Event.to_bytes event in
          Transport_metrics.inc_grpc_bytes_sent ~bytes:(String.length event_bytes);
          Grpc_eio.Stream.add stream event_bytes
        with
        | Eio.Cancel.Cancelled _ as e ->
          cleanup_subscriber ();
          raise e
        | exn -> cleanup_subscriber ~exn ()))
    ();
  (* Stream stays open; will be closed when the gRPC connection drops
     or the server shuts down. The callback auto-detects closed streams
     via Grpc_eio.Stream.is_closed and self-unsubscribes.
     The is_alive check also triggers auto-removal during broadcast. *)
  stream
;;

(** {1 Service Construction} *)

(** Create the gRPC service with all handlers wired to the given workspace config.

    @param workspace_config The MASC workspace configuration.
    @param tool_dispatcher Function that dispatches tool calls:
      [tool_name -> arguments_json -> (result_json, error_message) result].
    The dashboard IDE owns the sole LSP transport at [/api/v1/ide/lsp]. *)
let create_service
      ~(workspace_config : Workspace_utils_backend_setup.config)
      ~(tool_dispatcher :
          identity:Server_transport_admission.identity
          -> auth_token:string
          -> tool_name:string
          -> arguments:Yojson.Safe.t
          -> (string, string) result)
  : Grpc_eio.Service.t
  =
  Grpc_eio.Service.create service_name
  |> Grpc_eio.Service.add_unary "Broadcast" (handle_broadcast workspace_config)
  |> Grpc_eio.Service.add_unary "GetStatus" (handle_get_status workspace_config)
  |> Grpc_eio.Service.add_unary "ToolCall" (handle_tool_call workspace_config tool_dispatcher)
  |> Grpc_eio.Service.add_server_streaming "Subscribe" (handle_subscribe workspace_config)
  |> Grpc_eio.Service.add_bidi_streaming "Heartbeat" (handle_heartbeat workspace_config)
;;
