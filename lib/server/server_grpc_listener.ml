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

let listener_tag = "grpc"

type rpc_auth_identity = {
  auth_token : string option;
  internal_keeper : bool;
}

let rpc_auth_key : rpc_auth_identity Eio.Fiber.key = Eio.Fiber.create_key ()

let current_auth_token () =
  match Eio.Fiber.get rpc_auth_key with
  | Some { auth_token; _ } -> auth_token
  | None -> None

let current_internal_keeper () =
  match Eio.Fiber.get rpc_auth_key with
  | Some { internal_keeper; _ } -> internal_keeper
  | None -> false

let with_rpc_auth_identity identity f =
  Eio.Fiber.with_binding rpc_auth_key identity f

let respond_grpc_unauthenticated reqd message =
  let safe_msg = Uri.pct_encode ~component:`Query_value message in
  let headers =
    H2.Headers.of_list
      [ "content-type", "application/grpc"
      ; "grpc-status", "16"
      ; "grpc-message", safe_msg
      ]
  in
  H2.Reqd.respond_with_string reqd (H2.Response.create ~headers `OK) ""

let is_transient_accept_unix_error err =
  List.mem err
    [ Unix.ECONNABORTED
    ; Unix.ECONNRESET
    ; Unix.EMFILE
    ; Unix.ENFILE
    ; Unix.ENOBUFS
    ; Unix.ENOMEM
    ; Unix.EAGAIN
    ; Unix.EWOULDBLOCK
    ; Unix.EINTR
    ]

let serve_socket ?authorize_request ~sw ~clock ~socket server =
  let rec accept backoff_s =
    match
      Eio.Net.accept_fork socket ~sw
        ~on_error:(fun exn ->
          Eio.Fiber.check ();
          Log.Server.warn "gRPC connection failed: %s" (Printexc.to_string exn))
        (fun flow peer ->
          try
            Eio.Switch.run (fun conn_sw ->
              (* RFC-0518 D4, D6: the bounds of the HTTP listeners. A peer that
                 sends nothing, or stops taking what the server writes, is cut. *)
              let connection =
                Server_connection_socket.wrap ~sw:conn_sw ~clock ~listener_tag peer flow
              in
              match
                Server_connection_socket.prepare connection (fun () ->
                  Server_connection_socket.await_first_bytes connection)
              with
              | None ->
                  Log.Server.debug "[%s] %s sent nothing within %.0fs: connection closed"
                    listener_tag
                    (Format.asprintf "%a" Eio.Net.Sockaddr.pp peer)
                    Server_connection_socket.preparation_bound_s
              | Some () ->
                  Server_bootstrap_http.serve_h2_connection
                    ~clock
                    ~sw:conn_sw
                    ~h2_request_handler:(fun ~stream_end _peer reqd ->
                      let auth_decision =
                        match authorize_request with
                        | None -> Ok { auth_token = None; internal_keeper = false }
                        | Some check -> check (H2.Reqd.request reqd)
                      in
                      match auth_decision with
                      | Error message -> respond_grpc_unauthenticated reqd message
                      | Ok identity ->
                        Eio.Fiber.with_binding rpc_auth_key identity (fun () ->
                          Grpc_eio.Server.request_handler
                            ~sw:(Http_h2_stream.Stream_end.switch stream_end)
                            ~clock
                            server
                            reqd))
                    ~h2_error_handler:Grpc_eio.Server.error_handler
                    peer
                    (Server_connection_socket.socket connection))
          with
          | exn ->
            Eio.Fiber.check ();
            Log.Server.warn "gRPC connection failed: %s" (Printexc.to_string exn))
    with
    | () -> accept 0.05
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception
        (( Unix.Unix_error (err, _, _)
         | Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (err, _, _)), _) ) as exn)
      when is_transient_accept_unix_error err ->
      Log.Server.warn "gRPC transient accept error: %s" (Printexc.to_string exn);
      Eio.Time.sleep clock backoff_s;
      accept (Float.min 2.0 (backoff_s *. 1.5))
    | exception (Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) as exn) ->
      Log.Server.warn "gRPC transient accept reset: %s" (Printexc.to_string exn);
      Eio.Time.sleep clock backoff_s;
      accept (Float.min 2.0 (backoff_s *. 1.5))
  in
  accept 0.05

let serve ?authorize_request ~env ~port server =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  with_listener
    ~listen:(fun ~sw ->
      Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)))
    ~serve:(fun ~sw socket ->
      serve_socket ?authorize_request ~sw ~clock ~socket server)
