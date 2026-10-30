(** MASC gRPC Client.

    Client-side wrapper for the MascWorkspace gRPC service.
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
      Printf.sprintf "http://%s:%d" Masc_network_defaults.masc_http_default_host port
  in
  create ~sw ~env target

(** {1 Unary RPCs} *)

let heartbeat_stream t ~sw ~env =
  let request_stream = Grpc_eio.Stream.create 16 in
  (* Map typed pings to raw bytes *)
  let raw_requests = Grpc_eio.Stream.create 16 in
  Eio.Fiber.fork ~sw (fun () ->
    (* Both helpers must re-raise [Eio.Cancel.Cancelled] — they are called
       from the [End_of_file] and generic-[exn] branches of the enclosing
       loop (lines 177, 190-191), neither of which is a cancel handler.
       [with _ -> ()] would swallow a cancel racing with [Stream.close],
       leaving the fork fiber alive past the cancel boundary. *)
    let close_request_stream () =
      Safe_ops.protect ~default:() (fun () ->
        Grpc_eio.Stream.close request_stream)
    in
    let close_raw_requests () =
      Safe_ops.protect ~default:() (fun () ->
        Grpc_eio.Stream.close raw_requests)
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
