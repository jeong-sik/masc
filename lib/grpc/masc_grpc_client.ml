(** MASC gRPC Client.

    Client-side wrapper for the MascCoordination gRPC service.
    Uses grpc-direct [Client] for HTTP/2 transport. *)

module T = Masc_grpc_types

let service = Masc_grpc_service.service_name

(** {1 Connection} *)

type t = {
  client : Grpc_eio.Client.t;
}

let create ~sw ~env target =
  let config = Grpc_eio.Client.default_config ~target in
  let client = Grpc_eio.Client.connect ~config ~sw ~env target in
  { client }

let create_from_env ~sw ~env =
  let target =
    match Env_config.Transport.grpc_target_opt () with
    | Some t -> t
    | None ->
      let port = Masc_grpc_server.configured_port () in
      Printf.sprintf "http://127.0.0.1:%d" port
  in
  create ~sw ~env target

let close t =
  Grpc_eio.Client.close t.client

(** {1 Internal helpers} *)

(** Wrap a unary call with error handling. *)
let call_unary_safe t ~sw ~env ~method_ ~request ~decode =
  match
    Grpc_eio.Client.call_unary ~sw ~env t.client
      ~service ~method_ ~request
  with
  | Ok bytes -> (
    try Ok (decode bytes)
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Error (Printf.sprintf "decode error for %s: %s" method_
        (Printexc.to_string exn)))
  | Error status ->
    Error (Printf.sprintf "gRPC %s failed: %s" method_
      (Grpc_core.Status.to_string status))

(** {1 Unary RPCs} *)

let join t ~sw ~env ~agent_name ~capabilities ~metadata =
  let request = T.JoinRequest.to_bytes
    { agent_name; capabilities; metadata } in
  call_unary_safe t ~sw ~env ~method_:"Join" ~request
    ~decode:T.JoinResponse.of_bytes

let leave t ~sw ~env ~agent_name ~session_id =
  let request = T.LeaveRequest.to_bytes
    { agent_name; session_id } in
  call_unary_safe t ~sw ~env ~method_:"Leave" ~request
    ~decode:T.LeaveResponse.of_bytes

let get_status t ~sw ~env =
  (* StatusRequest is an empty protobuf message: 0 bytes on the wire. *)
  let request = "" in
  call_unary_safe t ~sw ~env ~method_:"GetStatus" ~request
    ~decode:T.StatusResponse.of_bytes

let tool_call t ~sw ~env ~agent_name ~session_id ~tool_name ~arguments_json =
  let request = T.ToolCallRequest.to_bytes
    { agent_name; session_id; tool_name; arguments_json } in
  call_unary_safe t ~sw ~env ~method_:"ToolCall" ~request
    ~decode:T.ToolCallResponse.of_bytes

let broadcast t ~sw ~env ~agent_name ~message ~mentions =
  let request = T.BroadcastRequest.(to_bytes { agent_name; message; mentions }) in
  call_unary_safe t ~sw ~env ~method_:"Broadcast" ~request
    ~decode:T.BroadcastResponse.of_bytes

(** {1 Streaming RPCs} *)

let subscribe t ~sw ~env ~agent_name ~session_id ~event_types ~since_seq =
  let request = T.SubscribeRequest_serde.to_bytes
    { agent_name; session_id; event_types; since_seq } in
  let raw_stream =
    Grpc_eio.Client.call_server_streaming ~sw ~env t.client
      ~service ~method_:"Subscribe" ~request
  in
  (* Transform raw stream items to typed events *)
  let typed_stream = Grpc_eio.Stream.create 64 in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      match Grpc_eio.Stream.take raw_stream with
      | Ok bytes ->
        (try
          Grpc_eio.Stream.add typed_stream (Ok (T.Event.of_bytes bytes))
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Grpc_eio.Stream.add typed_stream
            (Error (Printf.sprintf "event decode error: %s"
              (Printexc.to_string exn))));
        loop ()
      | Error status ->
        if not (Grpc_core.Status.is_ok status) then
          Grpc_eio.Stream.add typed_stream
            (Error (Printf.sprintf "subscribe stream error: %s"
              (Grpc_core.Status.to_string status)));
        Grpc_eio.Stream.close typed_stream
      | exception End_of_file ->
        Grpc_eio.Stream.close typed_stream
    in
    loop ());
  typed_stream

let heartbeat_stream t ~sw ~env =
  let request_stream = Grpc_eio.Stream.create 16 in
  (* Map typed pings to raw bytes *)
  let raw_requests = Grpc_eio.Stream.create 16 in
  Eio.Fiber.fork ~sw (fun () ->
    let close_request_stream () =
      try Grpc_eio.Stream.close request_stream with _ -> ()
    in
    let close_raw_requests () =
      try Grpc_eio.Stream.close raw_requests with _ -> ()
    in
    let rec loop () =
      match Grpc_eio.Stream.take request_stream with
      | bytes ->
        Grpc_eio.Stream.add raw_requests bytes;
        loop ()
      | exception End_of_file ->
        close_raw_requests ()
    in
    try loop ()
    with
    | Eio.Cancel.Cancelled _ as e ->
      (* Close both sides so senders and downstream receivers unblock. *)
      close_request_stream ();
      close_raw_requests ();
      raise e
    | exn ->
      Log.Transport.error
        "gRPC heartbeat request-mapper crashed: %s"
        (Printexc.to_string exn);
      close_request_stream ();
      close_raw_requests ());
  let raw_responses =
    Grpc_eio.Client.call_bidi ~sw ~env t.client
      ~service ~method_:"Heartbeat" ~requests:raw_requests
  in
  let send (ping : T.HeartbeatPing.t) =
    Grpc_eio.Stream.add request_stream (T.HeartbeatPing.to_bytes ping)
  in
  let recv () =
    match Grpc_eio.Stream.take raw_responses with
    | Ok bytes ->
      (try Ok (T.HeartbeatAck.of_bytes bytes)
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Error (Printf.sprintf "ack decode error: %s"
           (Printexc.to_string exn)))
    | Error status ->
      Error (Printf.sprintf "heartbeat stream error: %s"
        (Grpc_core.Status.to_string status))
  in
  let close_stream () =
    Grpc_eio.Stream.close request_stream
  in
  (send, recv, close_stream)
