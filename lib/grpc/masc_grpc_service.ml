(** MASC gRPC Coordination Service.

    Implements the MascCoordination gRPC service using grpc-direct.
    All handlers delegate to the Coord module for actual coordination logic.

    Wire format: protobuf binary via ocaml-protoc-plugin.
    See proto/masc_coordination.proto for the canonical API contract. *)

module T = Masc_grpc_types

(** Service name matching the proto package.service pattern. *)
let service_name = "masc.coordination.v1.MascCoordination"

(** Current timestamp in milliseconds. *)
let now_ms () = Int64.of_float (Unix.gettimeofday () *. 1000.0)

let decode_request_or_raise ~rpc decode bytes =
  match decode bytes with
  | Ok req -> req
  | Error msg ->
    Log.Transport.warn "gRPC %s decode failed: %s" rpc msg;
    Grpc_core.Status.raise_error Grpc_core.Status.Invalid_argument
      (Printf.sprintf "%s request decode failed: %s" rpc msg)

(** Read a file to string. Returns [""] on non-cancellation errors.
    Propagates [Eio.Cancel.Cancelled] so cooperative cancellation is preserved. *)
let read_file_safe path =
  try Fs_compat.load_file path
  with Eio.Cancel.Cancelled _ as e -> raise e
     | exn -> Log.Transport.warn "read_file_safe failed for %s: %s" path (Printexc.to_string exn); ""

(** Safe filename: replace non-alphanumeric chars with underscores. *)
let safe_filename name =
  String.map (fun c ->
    if (c >= 'a' && c <= 'z')
       || (c >= 'A' && c <= 'Z')
       || (c >= '0' && c <= '9')
       || c = '-' || c = '_'
    then c
    else '_') name

let task_assignee_of_status status =
  match Types.task_assignee_of_status status with
  | Some a -> a
  | None -> ""

let task_info_of_task (task : Types.task) : T.task_info =
  {
    T.id = task.id;
    title = task.title;
    status = Types.string_of_task_status task.task_status;
    assigned_to = task_assignee_of_status task.task_status;
    priority = task.priority;
  }

(** {1 Unary Handlers} *)

(** Join handler: agent joins the coordination room. *)
let handle_join (room_config : Coord_utils_backend_setup.config) (bytes : string) : string =
  let req =
    decode_request_or_raise ~rpc:"Join" T.JoinRequest.of_bytes_result bytes
  in
  let result =
    try
      let msg =
        Coord.join room_config
          ~agent_name:req.agent_name
          ~capabilities:req.capabilities
          ()
      in
      (* Read current agents for the response *)
      let agents_dir =
        Filename.concat
          (Filename.concat room_config.base_path ".masc")
          "agents"
      in
      let active_agents =
        if Sys.file_exists agents_dir && Sys.is_directory agents_dir then
          Sys.readdir agents_dir
          |> Array.to_list
          |> List.filter (fun f -> Filename.check_suffix f ".json")
          |> List.filter_map (fun f ->
            let path = Filename.concat agents_dir f in
            try
              let json = Yojson.Safe.from_string (read_file_safe path) in
              match Types.agent_of_yojson json with
              | Ok agent when agent.Types.status = Types.Active ->
                Some ({
                  T.name = agent.name;
                  status = "active";
                  capabilities = agent.capabilities;
                  last_heartbeat_ms = now_ms ();
                  joined_at_ms = now_ms ();
                  current_task_id =
                    Option.value ~default:"" agent.current_task;
                } : T.agent_info)
              | _ -> None
            with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Transport.debug "agent parse skip: %s" (Printexc.to_string exn); None)
        else []
      in
      T.JoinResponse.{
        success = true;
        message = msg;
        session_id = Printf.sprintf "grpc-%s-%Ld" req.agent_name (now_ms ());
        active_agents;
      }
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      T.JoinResponse.{
        success = false;
        message = Printf.sprintf "Join failed: %s" (Printexc.to_string exn);
        session_id = "";
        active_agents = [];
      }
  in
  T.JoinResponse.to_bytes result

(** Leave handler: agent leaves the coordination room. *)
let handle_leave (room_config : Coord_utils_backend_setup.config) (bytes : string) : string =
  let req =
    decode_request_or_raise ~rpc:"Leave" T.LeaveRequest.of_bytes_result bytes
  in
  let result =
    try
      let msg = Coord.leave room_config ~agent_name:req.agent_name in
      T.LeaveResponse.{ success = true; message = msg }
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      T.LeaveResponse.{
        success = false;
        message = Printf.sprintf "Leave failed: %s" (Printexc.to_string exn);
      }
  in
  T.LeaveResponse.to_bytes result

(** Broadcast handler: send a message to all agents. *)
let handle_broadcast (room_config : Coord_utils_backend_setup.config) (bytes : string) : string =
  let req =
    decode_request_or_raise ~rpc:"Broadcast" T.BroadcastRequest.of_bytes_result bytes
  in
  let result =
    try
      let content =
        if req.mentions = [] then req.message
        else
          let mention_prefix =
            String.concat " "
              (List.map (fun m -> "@" ^ m) req.mentions)
          in
          mention_prefix ^ " " ^ req.message
      in
      let _msg =
        Coord.broadcast room_config
          ~from_agent:req.agent_name ~content
      in
      T.BroadcastResponse.{ success = true; seq = now_ms () }
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Transport.error "gRPC broadcast failed: %s" (Printexc.to_string exn);
      T.BroadcastResponse.{ success = false; seq = 0L }
  in
  T.BroadcastResponse.to_bytes result

(** GetStatus handler: return current room state. *)
let handle_get_status (room_config : Coord_utils_backend_setup.config) (_bytes : string) : string =
  let masc_dir = Filename.concat room_config.base_path ".masc" in
  let agents_dir = Filename.concat masc_dir "agents" in
  let agents =
    if Sys.file_exists agents_dir && Sys.is_directory agents_dir then
      Sys.readdir agents_dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.filter_map (fun f ->
        let path = Filename.concat agents_dir f in
        try
          let json = Yojson.Safe.from_string (read_file_safe path) in
          match Types.agent_of_yojson json with
          | Ok agent ->
            let status_str = Types.agent_status_to_string agent.Types.status in
            Some ({
              T.name = agent.name;
              status = status_str;
              capabilities = agent.capabilities;
              last_heartbeat_ms = now_ms ();
              joined_at_ms = now_ms ();
              current_task_id =
                Option.value ~default:"" agent.current_task;
            } : T.agent_info)
          | _ -> None
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Log.Transport.debug "gRPC status: agent parse skip: %s"
            (Printexc.to_string exn);
          None)
    else []
  in
  let tasks = Coord.get_tasks_safe room_config |> List.map task_info_of_task in
  T.StatusResponse.(to_bytes {
    agents;
    tasks;
    message_count = 0;
    room_path = room_config.base_path;
  })

(** ToolCall handler: dispatch an MCP tool call via gRPC. *)
let handle_tool_call
    (tool_dispatcher : string -> string -> (string, string) result)
    (bytes : string) : string =
  let req =
    decode_request_or_raise ~rpc:"ToolCall" T.ToolCallRequest.of_bytes_result bytes
  in
  let result =
    match tool_dispatcher req.tool_name req.arguments_json with
    | Ok result_json ->
      T.ToolCallResponse.{
        success = true;
        result_json;
        error_message = "";
        error_code = 0;
      }
    | Error msg ->
      T.ToolCallResponse.{
        success = false;
        result_json = "";
        error_message = msg;
        error_code = -32603;
      }
  in
  T.ToolCallResponse.to_bytes result

(** {1 Streaming Handlers} *)

(** Active heartbeat stream count (atomic for signal safety). *)
let active_heartbeat_streams = Atomic.make 0

(** Active subscribe stream count (atomic for signal safety). *)
let active_subscribe_streams = Atomic.make 0

(** Compute directives for a keeper based on current room state.
    Returns a list of string directives to include in HeartbeatAck.
    Reads agent paused state and unclaimed tasks from the filesystem. *)
let compute_directives
    ~(room_config : Coord_utils_backend_setup.config)
    ~(agent_name : string) : string list =
  let masc_dir = Filename.concat room_config.base_path ".masc" in
  let directives = ref [] in
  (* 1. Pause directive: check if agent is marked paused *)
  let agent_file =
    Filename.concat
      (Filename.concat masc_dir "agents")
      (safe_filename agent_name ^ ".json")
  in
  (if Sys.file_exists agent_file then
    try
      let json = Yojson.Safe.from_string (read_file_safe agent_file) in
      (match Yojson.Safe.Util.member "paused" json with
       | `Bool true -> directives := "pause" :: !directives
       | _ -> ())
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Transport.warn
          "compute_directives: failed to parse agent file %s: %s"
          agent_file (Printexc.to_string exn));
  (* 2. Task assignment: find first unclaimed task for idle agent *)
  (if Coord.root_is_initialized room_config then
    let unclaimed =
      Coord.get_tasks_safe room_config
      |> List.filter_map (fun (task : Types.task) ->
           match task.task_status with
           | Types.Todo -> Some task.id
           | _ -> None)
    in
    match unclaimed with
    | task_id :: _ -> directives := ("claim:" ^ task_id) :: !directives
    | [] -> ());
  List.rev !directives

(** Heartbeat bidi handler: receive pings, respond with acks. *)
let handle_heartbeat
    (room_config : Coord_utils_backend_setup.config)
    ~(sw : Eio.Switch.t)
    (request_stream : string Grpc_eio.Stream.t)
  : string Grpc_eio.Stream.t =
  let response_stream = Grpc_eio.Stream.create 16 in
  Atomic.incr active_heartbeat_streams;
  Transport_metrics.set_grpc_active_streams (Atomic.get active_heartbeat_streams);
  Eio.Fiber.fork ~sw (fun () ->
    let cleanup () =
      Atomic.decr active_heartbeat_streams;
      Transport_metrics.set_grpc_active_streams
        (Atomic.get active_heartbeat_streams);
      (* Called from [End_of_file] at line 360 and the generic-[exn] handler
         at line 371 — neither is a cancel handler. [with _ -> ()] would
         swallow [Eio.Cancel.Cancelled] racing with [Stream.close], leaving
         the fiber to fall past the cancel boundary. The counters above are
         decremented first, so re-raising here is safe. *)
      (try Grpc_eio.Stream.close response_stream
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | _ -> ())
    in
    let rec loop () =
      match Grpc_eio.Stream.take request_stream with
      | bytes ->
        (try
          let t0 = Unix.gettimeofday () in
          let ping = T.HeartbeatPing.of_bytes bytes in
          (* Update agent last_seen *)
          (try
            let agent_file =
              Filename.concat
                (Filename.concat
                  (Filename.concat room_config.base_path ".masc")
                  "agents")
                (safe_filename ping.agent_name ^ ".json")
            in
            if Sys.file_exists agent_file then begin
              let json = Yojson.Safe.from_string (read_file_safe agent_file) in
              match Types.agent_of_yojson json with
              | Ok agent ->
                let now = Unix.gettimeofday () in
                let iso_now =
                  let tm = Unix.gmtime now in
                  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
                    (1900 + tm.tm_year) (1 + tm.tm_mon) tm.tm_mday
                    tm.tm_hour tm.tm_min tm.tm_sec
                in
                let updated = { agent with Types.last_seen = iso_now } in
                let content =
                  Yojson.Safe.to_string (Types.agent_to_yojson updated)
                in
                let tmp_path = agent_file ^ ".tmp" in
                Fs_compat.save_file tmp_path content;
                Unix.rename tmp_path agent_file
              | Error e ->
                  Log.Transport.warn "gRPC heartbeat: invalid agent JSON for %s: %s"
                    ping.agent_name e
            end
          with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Transport.error "gRPC heartbeat update failed: %s" (Printexc.to_string exn));
          (* Count active agents and pending tasks *)
          let masc_dir = Filename.concat room_config.base_path ".masc" in
          let agents_dir = Filename.concat masc_dir "agents" in
          let agent_count =
            if Sys.file_exists agents_dir then
              Array.length (Sys.readdir agents_dir)
            else 0
          in
          let tasks_dir = Filename.concat masc_dir "tasks" in
          let pending_count =
            if Sys.file_exists tasks_dir then
              Sys.readdir tasks_dir
              |> Array.to_list
              |> List.filter (fun f -> Filename.check_suffix f ".json")
              |> List.length
            else 0
          in
          let directives =
            compute_directives ~room_config ~agent_name:ping.agent_name
          in
          let ack = T.HeartbeatAck.{
            timestamp_ms = now_ms ();
            active_agent_count = agent_count;
            pending_task_count = pending_count;
            directives;
          } in
          Grpc_eio.Stream.add response_stream (T.HeartbeatAck.to_bytes ack);
          (* Record heartbeat latency *)
          let latency = Unix.gettimeofday () -. t0 in
          Transport_metrics.observe_grpc_heartbeat_latency latency
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Transport.error
             "gRPC heartbeat iteration crashed: %s"
             (Printexc.to_string exn));
        loop ()
      | exception End_of_file ->
        cleanup ()
    in
    try loop ()
    with
    | Eio.Cancel.Cancelled _ as e ->
      cleanup ();
      raise e
    | exn ->
      Log.Transport.error
        "gRPC heartbeat fiber died outside iteration: %s"
        (Printexc.to_string exn);
      cleanup ());
  response_stream

(** Subscribe server-streaming handler: push room events to the agent. *)
let handle_subscribe
    (room_config : Coord_utils_backend_setup.config)
    (bytes : string)
  : string Grpc_eio.Stream.t =
  let req =
    decode_request_or_raise ~rpc:"Subscribe" T.SubscribeRequest.of_bytes_result bytes
  in
  let stream = Grpc_eio.Stream.create 64 in
  Atomic.incr active_subscribe_streams;
  Transport_metrics.set_grpc_subscribers (Atomic.get active_subscribe_streams);
  let events_count = ref 0 in
  let stream_closed = Atomic.make false in
  let sub_id = Printf.sprintf "grpc-subscribe-%s-%Ld"
    req.agent_name (now_ms ()) in
  let cleanup_subscriber ?exn () =
    if Atomic.compare_and_set stream_closed false true then begin
      Sse.unsubscribe_external sub_id;
      Atomic.decr active_subscribe_streams;
      Transport_metrics.set_grpc_subscribers
        (Atomic.get active_subscribe_streams);
      Option.iter
        (fun err ->
          Log.Misc.warn "gRPC subscriber %s failed: %s" sub_id
            (Printexc.to_string err))
        exn;
      Log.Misc.info "gRPC subscriber %s cleaned up" sub_id
    end
  in
  (* Send initial event confirming subscription *)
  let init_event = T.Event.{
    seq = 0L;
    event_type = "subscription_started";
    source_agent = "server";
    timestamp_ms = now_ms ();
    payload_json = Printf.sprintf
      {|{"agent_name":"%s","event_types":%s}|}
      req.agent_name
      (Yojson.Safe.to_string
        (`List (List.map (fun s -> `String s) req.event_types)));
  } in
  Grpc_eio.Stream.add stream (T.Event.to_bytes init_event);
  incr events_count;
  (* Read recent messages and push as events *)
  let backlog_file =
    Filename.concat
      (Filename.concat room_config.base_path ".masc")
      "backlog.jsonl"
  in
  if Sys.file_exists backlog_file then begin
    let content = Fs_compat.load_file backlog_file in
    let lines = String.split_on_char '\n' content in
    let seq = ref 1L in
    List.iter (fun line ->
      if String.length line > 0 then begin
        let msg_seq = !seq in
        if Int64.compare msg_seq req.since_seq > 0 then begin
          let event = T.Event.{
            seq = msg_seq;
            event_type = "message";
            source_agent = "";
            timestamp_ms = now_ms ();
            payload_json = line;
          } in
          Grpc_eio.Stream.add stream (T.Event.to_bytes event);
          incr events_count
        end;
        seq := Int64.add !seq 1L
      end
    ) lines
  end;
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
  let max_buffer = 48 in (* stream capacity is 64; leave headroom *)
  Sse.subscribe_external ~id:sub_id
    ~is_alive:(fun () ->
      not (Atomic.get stream_closed) && not (Grpc_eio.Stream.is_closed stream))
    ~callback:(fun sse_event ->
    if Atomic.get stream_closed || Grpc_eio.Stream.is_closed stream then begin
      (* Stream already gone — auto-cleanup *)
      cleanup_subscriber ()
    end else if Grpc_eio.Stream.length stream >= max_buffer then
      (* Stream buffer near-full — drop event to avoid blocking broadcast *)
      Log.Misc.warn "gRPC subscriber %s: buffer full (%d), dropping event"
        sub_id (Grpc_eio.Stream.length stream)
    else begin
      let seq = Int64.of_int (Atomic.fetch_and_add seq_counter 1) in
      let event = T.Event.{
        seq;
        event_type = "sse_broadcast";
        source_agent = "server";
        timestamp_ms = now_ms ();
        payload_json = sse_event;
      } in
      try Grpc_eio.Stream.add stream (T.Event.to_bytes event)
      with
      | Eio.Cancel.Cancelled _ as e ->
        cleanup_subscriber ();
        raise e
      | exn ->
        cleanup_subscriber ~exn ()
    end
  ) ();
  (* Stream stays open; will be closed when the gRPC connection drops
     or the server shuts down. The callback auto-detects closed streams
     via Grpc_eio.Stream.is_closed and self-unsubscribes.
     The is_alive check also triggers auto-removal during broadcast. *)
  stream

(** {1 Service Construction} *)

(** Create the gRPC service with all handlers wired to the given room config.

    @param room_config The MASC room configuration.
    @param tool_dispatcher Function that dispatches tool calls:
      [tool_name -> arguments_json -> (result_json, error_message) result]. *)
let create_service
    ~(room_config : Coord_utils_backend_setup.config)
    ~(tool_dispatcher : string -> string -> (string, string) result)
  : Grpc_eio.Service.t =
  Grpc_eio.Service.create service_name
  |> Grpc_eio.Service.add_unary "Join" (handle_join room_config)
  |> Grpc_eio.Service.add_unary "Leave" (handle_leave room_config)
  |> Grpc_eio.Service.add_unary "Broadcast" (handle_broadcast room_config)
  |> Grpc_eio.Service.add_unary "GetStatus" (handle_get_status room_config)
  |> Grpc_eio.Service.add_unary "ToolCall" (handle_tool_call tool_dispatcher)
  |> Grpc_eio.Service.add_server_streaming "Subscribe"
    (handle_subscribe room_config)
  |> Grpc_eio.Service.add_bidi_streaming "Heartbeat"
    (handle_heartbeat room_config)
