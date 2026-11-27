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
  let raw_requests = Grpc_eio.Stream.create 16 in
  let raw_responses =
    match
      Grpc_eio.Client.call_bidi ~sw ~env t.client
        ~service ~method_:"Heartbeat" ~requests:raw_requests
    with
    | stream -> stream
    | exception exn ->
      let bt = Printexc.get_raw_backtrace () in
      Grpc_eio.Stream.close raw_requests;
      Printexc.raise_with_backtrace exn bt
  in
  let send (ping : T.HeartbeatPing.t) =
    Grpc_eio.Stream.add raw_requests (T.HeartbeatPing.to_bytes ping)
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
    Grpc_eio.Stream.close raw_requests
  in
  (send, recv, close_stream)
