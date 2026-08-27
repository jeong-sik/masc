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

(** {1 Unary Handlers} *)

(** Broadcast handler: send a message to all agents. *)
let handle_broadcast (workspace_config : Workspace_utils_backend_setup.config) (bytes : string)
  : string
  =
  let req =
    decode_request_or_raise ~rpc:"Broadcast" T.BroadcastRequest.of_bytes_result bytes
  in
  let result =
    if List.length req.mentions > 1
    then
      T.BroadcastResponse.
        { success = false
        ; seq = 0L
        ; request_id = None
        ; delivery_status = Delivery_not_persisted
        ; delivery_reason = Some "multiple_mention_targets_unsupported"
        ; workspace_persistence_status = Workspace_not_persisted
        ; retry_disposition = Retry_allowed
        }
    else try
      let content =
        if req.mentions = []
        then req.message
        else (
          let mention_prefix =
            String.concat " " (List.map (fun m -> "@" ^ m) req.mentions)
          in
          mention_prefix ^ " " ^ req.message)
      in
      (* An agent broadcasting over gRPC is speaking, same as the MCP tool;
         the request even carries explicit mention targets. *)
      (match
         Workspace.broadcast
           ~audience:Workspace_broadcast.Fleet_conversation
           workspace_config ~from_agent:req.agent_name ~content
       with
       | Ok delivery ->
         let success =
           match delivery.mention_delivery with
           | Workspace_broadcast.Passive
           | Workspace_broadcast.Accepted
           | Workspace_broadcast.Already_accepted -> true
           | Workspace_broadcast.Pending
           | Workspace_broadcast.Deferred _
           | Workspace_broadcast.Rejected _ -> false
         in
         T.BroadcastResponse.
           { success
           ; seq = Int64.of_int delivery.seq
           ; request_id = Some delivery.request_id
           ; delivery_status =
               (match delivery.mention_delivery with
                | Workspace_broadcast.Passive -> Delivery_passive
                | Workspace_broadcast.Accepted -> Delivery_accepted
                | Workspace_broadcast.Already_accepted -> Delivery_already_accepted
                | Workspace_broadcast.Pending -> Delivery_pending
                | Workspace_broadcast.Deferred _ -> Delivery_deferred
                | Workspace_broadcast.Rejected _ -> Delivery_rejected)
           ; delivery_reason =
               Workspace_broadcast.mention_delivery_reason delivery.mention_delivery
           ; workspace_persistence_status = Workspace_persisted
           ; retry_disposition = Retry_do_not_resend
           }
       | Error error ->
         Log.Transport.error
           "gRPC broadcast was not persisted: %s"
           (Workspace.broadcast_error_to_string error);
         T.BroadcastResponse.
           { success = false
           ; seq = 0L
           ; request_id = None
           ; delivery_status = Delivery_not_persisted
           ; delivery_reason = Some (Workspace.broadcast_error_to_string error)
           ; workspace_persistence_status = Workspace_not_persisted
           ; retry_disposition = Retry_allowed
           })
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Transport.error "gRPC broadcast failed: %s" (Printexc.to_string exn);
      T.BroadcastResponse.
        { success = false
        ; seq = 0L
        ; request_id = None
        ; delivery_status = Delivery_outcome_unknown
        ; delivery_reason = Some (Printexc.to_string exn)
        ; workspace_persistence_status = Workspace_persistence_unknown
        ; retry_disposition = Retry_outcome_unknown
        }
  in
  T.BroadcastResponse.to_bytes result
;;

(** GetStatus handler: return current workspace state. *)
let handle_get_status (workspace_config : Workspace_utils_backend_setup.config) (_bytes : string)
  : string
  =
  let agents =
    Workspace.get_all_agents workspace_config
    |> List.map (fun (agent : Masc_domain.agent) ->
      ({ T.name = agent.name
       ; status = Masc_domain.agent_status_to_string agent.status
       ; capabilities = agent.capabilities
       ; last_heartbeat_ms = now_ms ()
       ; session_bound_at_ms = now_ms ()
       ; current_task_id = Option.value ~default:"" agent.current_task
       }
       : T.agent_info))
  in
  let tasks = Workspace.get_tasks_safe workspace_config |> List.map task_info_of_task in
  T.StatusResponse.(
    to_bytes { agents; tasks; message_count = 0; workspace_path = workspace_config.base_path })
;;

(** ToolCall handler: dispatch an MCP tool call via gRPC. *)
let handle_tool_call
      (tool_dispatcher :
         string ->
         string ->
         (string, Server_grpc_tool_dispatch.error) result)
      (bytes : string)
  : string
  =
  let req =
    decode_request_or_raise ~rpc:"ToolCall" T.ToolCallRequest.of_bytes_result bytes
  in
  let result =
    match tool_dispatcher req.tool_name req.arguments_json with
    | Ok result_json ->
      T.ToolCallResponse.
        { success = true; result_json; error_message = ""; error_code = 0 }
    | Error error ->
      T.ToolCallResponse.
        { success = false
        ; result_json = ""
        ; error_message = Server_grpc_tool_dispatch.error_message error
        ; error_code =
            Server_grpc_tool_dispatch.error_code error
            |> Mcp_error_code.to_wire_code
        }
  in
  T.ToolCallResponse.to_bytes result
;;


(** {1 Streaming Handlers} *)

(** Active heartbeat stream count (atomic for signal safety). *)
let active_heartbeat_streams = Atomic.make 0

(** Active subscribe stream count (atomic for signal safety). *)
let active_subscribe_streams = Atomic.make 0

type task_directive_decision =
  | No_task_directive
  | Assign_task of Keeper_id.Task_id.t
  | Invalid_task_id of
      { task_id : string
      ; error : string
      }

type heartbeat_workspace_view =
  { keeper_paused : bool
  ; active_agent_count : int
  ; pending_task_count : int
  ; task_directive : task_directive_decision
  }

let task_is_pending (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Todo
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.AwaitingVerification _ -> true
  | Masc_domain.Done _ | Masc_domain.Cancelled _ -> false
;;

let decide_task_directive tasks =
  let rec first_todo = function
    | [] -> No_task_directive
    | (task : Masc_domain.task) :: rest ->
      (match task.task_status with
       | Masc_domain.Todo ->
         (match Keeper_id.Task_id.of_string task.id with
          | Ok task_id -> Assign_task task_id
          | Error error -> Invalid_task_id { task_id = task.id; error })
       | Masc_domain.Claimed _
       | Masc_domain.InProgress _
       | Masc_domain.AwaitingVerification _
       | Masc_domain.Done _
       | Masc_domain.Cancelled _ ->
         first_todo rest)
  in
  first_todo tasks
;;

(** Pure projection from authoritative Workspace and Keeper snapshots. *)
let heartbeat_workspace_view ~keeper_paused ~active_agents ~tasks =
  { keeper_paused
  ; active_agent_count = List.length active_agents
  ; pending_task_count =
      List.fold_left
        (fun count task -> if task_is_pending task then count + 1 else count)
        0
        tasks
  ; task_directive = decide_task_directive tasks
  }
;;

(** Durable Keeper pause for one heartbeat ping, read from the live registry
    only.

    Scope: this answers "does a Keeper lane in this base_path currently hold a
    durable pause", so a Keeper that exists only in persisted metadata is
    [false] — it owns no lane to park. [Keeper_identity_binding.resolve] is the
    authority for name resolution and does consult persisted metadata, but its
    fallback lists every persisted Keeper and reads each meta file; the
    heartbeat runs every 30s per connected agent and most pings come from
    agents that are not Keepers at all, so that scan does not belong here.

    The multi-entry branch is unreachable defence, not a policy choice.
    [Keeper_identity.keeper_agent_name] makes agent_name a bijection of the
    Keeper name ("keeper-<name>-agent"); the parse boundary rejects metadata
    that breaks it, and [Keeper_registry.all] re-validates every entry on read
    and drops the ones that fail, so two entries sharing one agent_name cannot
    reach this scan. It still resolves to no directive rather than picking a
    lane: a Pause the client accepts commits
    [Keeper_latched_reason.Operator_paused], which only the receipt-first
    [Resume_owner] transaction can clear, so a misaddressed pause is durable
    while a skipped one is retried on the next ping. *)
let keeper_paused_for_heartbeat ~base_path ~agent_name =
  match Keeper_registry_lookup.find_by_name_in_base_path ~base_path agent_name with
  | None -> false
  | Some entry -> entry.meta.paused
;;

let directives_of_view ~agent_name view =
  let task_directives =
    match view.task_directive with
    | No_task_directive -> []
    | Assign_task task_id -> [ Keeper_directive.Assign_task task_id ]
    | Invalid_task_id { task_id; error } ->
      Log.Transport.error
        "gRPC heartbeat: invalid task id %S for keeper %s: %s"
        task_id
        agent_name
        error;
      []
  in
  if view.keeper_paused
  then Keeper_directive.Pause :: task_directives
  else task_directives
;;

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
         at line 371 — neither is a cancel handler. [with _ -> ()] would (* cancel-guard-ok: prose; the code below re-raises *)
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
        (match T.HeartbeatPing.of_bytes_result bytes with
         | Error msg -> Log.Transport.warn "gRPC Heartbeat decode failed: %s" msg
         | Ok ping ->
           (try
              let t0 = Unix.gettimeofday () in
              if Workspace.root_is_initialized workspace_config
              then (
                match Workspace.heartbeat workspace_config ~agent_name:ping.agent_name with
                | Workspace.Heartbeat_updated _ | Workspace.Agent_not_found _ -> ()
                | Workspace.Agent_file_invalid actual_name ->
                  Log.Transport.warn
                    "gRPC heartbeat: invalid agent JSON for %s"
                    actual_name);
              let active_agents = Workspace.get_active_agents workspace_config in
              let tasks = Workspace.get_tasks_safe workspace_config in
              let view =
                heartbeat_workspace_view
                  ~keeper_paused:
                    (keeper_paused_for_heartbeat
                       ~base_path:workspace_config.base_path
                       ~agent_name:ping.agent_name)
                  ~active_agents
                  ~tasks
              in
              let directives = directives_of_view ~agent_name:ping.agent_name view in
              let ack =
                T.HeartbeatAck.
                  { timestamp_ms = now_ms ()
                  ; active_agent_count = view.active_agent_count
                  ; pending_task_count = view.pending_task_count
                  ; directives
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
                (Printexc.to_string exn)));
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
let handle_subscribe (bytes : string) : string Grpc_eio.Stream.t =
  let req =
    decode_request_or_raise ~rpc:"Subscribe" T.SubscribeRequest.of_bytes_result bytes
  in
  (* [since_seq] is declared as "resume from this sequence number", and this
     endpoint serves no backlog: the only thing it does with the field is seed
     the outgoing counter, so a client asking to resume from 100 gets the next
     live event labelled 101 and never learns the events between were dropped.
     Numbering that reads as continuous over a gap is worse than refusing, so
     it refuses. Replay itself is #30399; when it lands this goes away. *)
  if not (Int64.equal req.since_seq 0L)
  then
    Grpc_core.Status.raise_error
      Grpc_core.Status.Unimplemented
      (Printf.sprintf
         "Subscribe does not serve a backlog; since_seq=%Ld cannot be honoured. Send \
          since_seq=0 to stream from now, and read the missed range with the \
          workspace message tools, which do take since_seq."
         req.since_seq);
  let stream = Grpc_eio.Stream.create 64 in
  Atomic.incr active_subscribe_streams;
  Transport_metrics.set_grpc_subscribers (Atomic.get active_subscribe_streams);
  let events_count = ref 0 in
  let stream_closed = Atomic.make false in
  let sub_id = Printf.sprintf "grpc-subscribe-%s-%Ld" req.agent_name (now_ms ()) in
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
            req.agent_name
            (Yojson.Safe.to_string
               (`List (List.map (fun s -> `String s) req.event_types)))
      }
  in
  let init_bytes = T.Event.to_bytes init_event in
  Transport_metrics.inc_grpc_bytes_sent ~bytes:(String.length init_bytes);
  Grpc_eio.Stream.add stream init_bytes;
  incr events_count;
  Transport_metrics.inc_grpc_events_delivered ~delta:!events_count ();
  (* Hook into SSE broadcast mechanism for real-time event push.
     External subscriber receives formatted SSE event strings on every
     Sse.broadcast/broadcast_to call, converts them to gRPC Event messages,
     and pushes into the gRPC response stream.

     IMPORTANT: The callback runs synchronously inside broadcast_impl,
     so it MUST NOT block. We use Grpc_eio.Stream.length to check
     capacity before adding. If the stream is full or closed, the event
     is dropped and the subscriber auto-unregisters. *)
  (* Refused above unless zero, so this is always 1: the stream starts at the
     first event it actually carries. *)
  let seq_counter = Atomic.make (Int64.to_int req.since_seq + 1) in
  (* Read once per subscribe so existing streams are not disturbed
     mid-flight by a config change; newly-subscribing clients pick up
     the new value. *)
  let max_buffer = stream_max_buffer () in
  Sse.subscribe_external
    ~id:sub_id
    ~is_alive:(fun () ->
      (not (Atomic.get stream_closed)) && not (Grpc_eio.Stream.is_closed stream))
    ~callback:(fun (ev : Sse.external_event) ->
      let sse_event = ev.Sse.ext_frame in
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
    @param tool_dispatcher Function that dispatches typed tool calls. *)
let create_service
      ~(workspace_config : Workspace_utils_backend_setup.config)
      ~(tool_dispatcher :
         string ->
         string ->
         (string, Server_grpc_tool_dispatch.error) result)
  : Grpc_eio.Service.t
  =
  Grpc_eio.Service.create service_name
  |> Grpc_eio.Service.add_unary "Broadcast" (handle_broadcast workspace_config)
  |> Grpc_eio.Service.add_unary "GetStatus" (handle_get_status workspace_config)
  |> Grpc_eio.Service.add_unary "ToolCall" (handle_tool_call tool_dispatcher)
  |> Grpc_eio.Service.add_server_streaming "Subscribe" handle_subscribe
  |> Grpc_eio.Service.add_bidi_streaming "Heartbeat" (handle_heartbeat workspace_config)
;;
