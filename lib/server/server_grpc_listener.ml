type failure = {
  kind : Transport_metrics.grpc_listener_failure;
  cause : exn;
}

type phase = Bind | Serve

let bind_failure = function
  | Unix.Unix_error (error, _, _)
  | Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (error, _, _)), _)
    when error = Unix.EADDRINUSE ->
      Transport_metrics.Address_in_use
  | _ -> Transport_metrics.Bind_failed

let with_listener ~listen ~serve =
  let phase = ref Bind in
  Transport_metrics.set_grpc_listener_state Binding;
  try
    Eio.Switch.run (fun sw ->
      let socket = listen ~sw in
      Eio.Fiber.check ();
      phase := Serve;
      Transport_metrics.set_grpc_listener_state Listening;
      serve ~sw socket);
    Transport_metrics.set_grpc_listener_state Stopped;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn ->
      Transport_metrics.set_grpc_listener_state Stopped;
      raise exn
  | cause ->
      let kind =
        match !phase with
        | Bind -> bind_failure cause
        | Serve -> Transport_metrics.Serve_failed
      in
      Transport_metrics.set_grpc_listener_state (Failed kind);
      Error { kind; cause }

let serve_socket ~sw ~clock ~socket server =
  let rec accept () =
    Eio.Net.accept_fork socket ~sw
      ~on_error:(function
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            Log.Server.warn "gRPC connection failed: %s" (Printexc.to_string exn))
      (fun flow peer ->
        Eio.Switch.run (fun conn_sw ->
          Server_bootstrap_http.serve_h2_connection
            ~sw:conn_sw
            ~h2_request_handler:(fun ~request_sw _peer reqd ->
              Grpc_eio.Server.request_handler ~sw:request_sw ~clock server reqd)
            ~h2_error_handler:Grpc_eio.Server.error_handler
            peer flow));
    accept ()
  in
  accept ()

let serve ~env ~port server =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  with_listener
    ~listen:(fun ~sw ->
      Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)))
    ~serve:(fun ~sw socket -> serve_socket ~sw ~clock ~socket server)
