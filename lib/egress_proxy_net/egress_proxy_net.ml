type outcome =
  | Admitted of { host : string; port : int }
  | Refused of { detail : string }
  | Upstream_failed of { host : string; port : int; detail : string }
  | Unreadable of { detail : string }

let outcome_to_string = function
  | Admitted { host; port } -> Printf.sprintf "admitted %s:%d" host port
  | Refused { detail } -> "refused: " ^ detail
  | Upstream_failed { host; port; detail } ->
    Printf.sprintf "upstream %s:%d failed: %s" host port detail
  | Unreadable { detail } -> "unreadable: " ^ detail
;;

type event =
  { keeper_name : string
  ; at : float
  ; outcome : outcome
  }

(* The request line and the header block that follows it. A CONNECT authority
   that needs more than this is not a hostname, and the cap is what keeps a
   client from holding a fiber open by never sending the blank line. *)
let request_head_max_bytes = 8 * 1024
let request_line_max_bytes = request_head_max_bytes

let resolve_upstream ~net ~host ~port =
  let name = Egress_host.to_string host in
  match Eio.Net.getaddrinfo_stream net name ~service:(string_of_int port) with
  | [] -> Error (Printf.sprintf "no address for %s" name)
  | address :: _ -> Ok address
  | exception exn -> Error (Printexc.to_string exn)
;;

let write_all flow text = Eio.Flow.copy_string text flow

(* Both directions, and either close ends the pair. A half-closed tunnel
   would keep a fiber and a socket alive after the peer is gone, which on a
   lane whose whole job is to bound reach is the wrong kind of leak.

   Cancellation is re-raised rather than swallowed. A bare [with _ -> ()]
   here caught [Eio.Cancel.Cancelled] too, so a lane being torn down waited
   on however long the tunnel lived -- and a keeper's shutdown joined on a
   connection to somewhere else. *)
let ignore_flow_error f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | _ -> ()
;;

let splice ~client ~upstream =
  Eio.Fiber.both
    (fun () ->
      ignore_flow_error (fun () -> Eio.Flow.copy client upstream);
      ignore_flow_error (fun () -> Eio.Flow.shutdown upstream `Send))
    (fun () ->
      ignore_flow_error (fun () -> Eio.Flow.copy upstream client);
      ignore_flow_error (fun () -> Eio.Flow.shutdown client `Send))
;;

let handle_connection ~net ~clock ~keeper_name ~rules ~on_event ~read_timeout_s flow =
  let emit outcome = on_event { keeper_name; at = Unix.gettimeofday (); outcome } in
  let read_request_line () =
    (* The whole request head, not just its first line. A CONNECT carries a
       header block ending in a blank line, and splicing with those still
       unread put them into the upstream stream ahead of the client's TLS
       ClientHello -- which upstream reads as a malformed handshake, on a
       schedule that depends on how the client segmented its write.

       The timeout covers reading the head, not the tunnel: a client that
       connects and says nothing must not hold the fiber, while an admitted
       tunnel is allowed to be long-lived. *)
    Eio.Time.with_timeout clock read_timeout_s (fun () ->
      let reader = Eio.Buf_read.of_flow flow ~max_size:request_head_max_bytes in
      let request_line = Eio.Buf_read.line reader in
      let rec consume_headers () =
        match Eio.Buf_read.line reader with
        | "" | "\r" -> ()
        | _ -> consume_headers ()
      in
      consume_headers ();
      Ok (request_line, reader))
  in
  match read_request_line () with
  | Error `Timeout ->
    emit (Unreadable { detail = "no request line before the read timeout" })
  | exception End_of_file -> emit (Unreadable { detail = "client closed before sending a line" })
  | exception Eio.Buf_read.Buffer_limit_exceeded ->
    emit
      (Unreadable
         { detail =
             Printf.sprintf "request head over %d bytes" request_head_max_bytes
         })
  | Ok (request_line, reader) ->
    let decision = Egress_proxy_decision.decide ~rules ~request_line in
    (match decision with
     | Egress_proxy_decision.Refused refusal ->
       emit (Refused { detail = Egress_proxy_decision.refusal_to_string refusal });
       (try write_all flow (Egress_proxy_decision.response_of_decision decision) with _ -> ())
     | Egress_proxy_decision.Admitted { host; port } ->
       let host_text = Egress_host.to_string host in
       (* Resolution happens here and nowhere earlier: the name the resolver
          is handed is the name the allowlist just admitted, so there is no
          second reading of the bytes to disagree with the first. *)
       (match resolve_upstream ~net ~host ~port with
        | Error detail ->
          emit (Upstream_failed { host = host_text; port; detail });
          (try
             write_all
               flow
               (Egress_proxy_decision.response_of_decision
                  (Egress_proxy_decision.Refused
                     (Egress_proxy_decision.Malformed_request
                        ("upstream is unreachable: " ^ detail))))
           with _ -> ())
        | Ok address ->
          Eio.Switch.run (fun upstream_sw ->
            match Eio.Net.connect ~sw:upstream_sw net address with
            | exception exn ->
              emit
                (Upstream_failed
                   { host = host_text; port; detail = Printexc.to_string exn })
            | upstream ->
              emit (Admitted { host = host_text; port });
              (try write_all flow (Egress_proxy_decision.response_of_decision decision) with
               | _ -> ());
              (* Whatever the reader buffered past the blank line is already
                 the tunnel's first bytes -- a client that writes its head and
                 its ClientHello in one segment leaves them here. Dropping
                 them stalls the handshake; the splice below reads from the
                 flow and would never see them. *)
              (try
                 let buffered = Eio.Buf_read.peek reader in
                 if Cstruct.length buffered > 0
                 then (
                   Eio.Flow.copy_string (Cstruct.to_string buffered) upstream;
                   Eio.Buf_read.consume reader (Cstruct.length buffered))
               with _ -> ());
              splice ~client:flow ~upstream)))
;;

let serve ~sw ~net ~clock ~keeper_name ~rules ~on_event ~socket ~read_timeout_s =
  let rec accept_loop () =
    Eio.Net.accept_fork
      ~sw
      socket
      ~on_error:(fun exn ->
        on_event
          { keeper_name
          ; at = Unix.gettimeofday ()
          ; outcome = Unreadable { detail = Printexc.to_string exn }
          })
      (fun flow _client_addr ->
        handle_connection ~net ~clock ~keeper_name ~rules ~on_event ~read_timeout_s flow);
    accept_loop ()
  in
  accept_loop ()
;;
