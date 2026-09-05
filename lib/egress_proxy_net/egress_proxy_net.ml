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
  ; rule_generation : string option
  }

(* The request line and the header block that follows it. A CONNECT authority
   that needs more than this is not a hostname, and the cap is what keeps a
   client from holding a fiber open by never sending the blank line. *)
let request_head_max_bytes = 8 * 1024
let request_line_max_bytes = request_head_max_bytes

(* Every address the name resolves to, in the order the resolver gave them.
   Taking the first alone meant a host whose first record was unreachable --
   an IPv6 address on a host with no IPv6 route, a machine that is down in a
   round-robin -- failed as if the whole destination were gone, while the
   next address would have answered. *)
let resolve_upstream ~net ~host ~port =
  let name = Egress_host.to_string host in
  match Eio.Net.getaddrinfo_stream net name ~service:(string_of_int port) with
  | [] -> Error (Printf.sprintf "no address for %s" name)
  | addresses -> Ok addresses
  | exception exn -> Error (Printexc.to_string exn)
;;

(* Try them in order and report the last failure. Reporting the first would
   name whichever address the resolver happened to put first rather than the
   one that ended the attempt. *)
let connect_first_reachable ~sw ~net addresses =
  let rec attempt last_error = function
    | [] ->
      Error (Option.value last_error ~default:"no address answered")
    | address :: rest ->
      (match Eio.Net.connect ~sw net address with
       | flow -> Ok flow
       | exception exn ->
         (match exn with
          (* A cancelled switch is the lane going away, not this address
             failing; trying the next one would outlive the reason to try. *)
          | Eio.Cancel.Cancelled _ -> raise exn
          (* Only an I/O failure says "this address did not answer". A
             malformed address raises [Invalid_argument], and moving on from
             that would report a code defect as an unreachable destination
             and then hide it behind "no address answered". *)
          | Eio.Io _ -> attempt (Some (Printexc.to_string exn)) rest
          | _ -> raise exn))
  in
  attempt None addresses
;;

(* A peer that closed mid-copy is the ordinary end of a tunnel, not a
   failure worth propagating. That is [Eio.Io _] on a write and [End_of_file]
   on a read, and those two are what this drops.

   Everything else goes up. A bare [_] here read as "ignore the flow error"
   while also erasing [Invalid_argument] and [Not_found] -- code defects in
   this file, reported as a peer hanging up. *)
let ignore_flow_error f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Eio.Io _ | End_of_file -> ()
;;

let write_all flow text = Eio.Flow.copy_string text flow

(* Both directions, and either close ends the pair. A half-closed tunnel
   would keep a fiber and a socket alive after the peer is gone, which on a
   lane whose whole job is to bound reach is the wrong kind of leak.

   Cancellation is re-raised rather than swallowed. A bare [with _ -> ()]
   here caught [Eio.Cancel.Cancelled] too, so a lane being torn down waited
   on however long the tunnel lived -- and a keeper's shutdown joined on a
   connection to somewhere else. *)

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
  (* The generation of whatever judged this request, or [None] where nothing
     was judged. It is set from the very list [decide] was given, not read a
     second time: rules are asked per request, so a second read could answer
     a different allowlist than the one that decided. *)
  let judged_by = ref None in
  let emit outcome =
    on_event
      { keeper_name
      ; at = Unix.gettimeofday ()
      ; outcome
      ; rule_generation = !judged_by
      }
  in
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
    (* Asked here, per request, so an allowlist edit reaches the next
       connection instead of waiting for a lane restart. *)
    let rules = rules () in
    judged_by := Some (Egress_host.generation rules);
    let decision = Egress_proxy_decision.decide ~rules ~request_line in
    (match decision with
     | Egress_proxy_decision.Refused refusal ->
       emit (Refused { detail = Egress_proxy_decision.refusal_to_string refusal });
       ignore_flow_error (fun () ->
         write_all flow (Egress_proxy_decision.response_of_decision decision))
     | Egress_proxy_decision.Admitted { host; port } ->
       let host_text = Egress_host.to_string host in
       (* Resolution happens here and nowhere earlier: the name the resolver
          is handed is the name the allowlist just admitted, so there is no
          second reading of the bytes to disagree with the first. *)
       (match resolve_upstream ~net ~host ~port with
        | Error detail ->
          emit (Upstream_failed { host = host_text; port; detail });
          ignore_flow_error (fun () ->
            write_all
              flow
              (Egress_proxy_decision.response_of_decision
                 (Egress_proxy_decision.Refused
                    (Egress_proxy_decision.Upstream_unreachable
                       { host = host_text; port; detail }))))
        | Ok addresses ->
          Eio.Switch.run (fun upstream_sw ->
            match connect_first_reachable ~sw:upstream_sw ~net addresses with
            | Error detail ->
              emit (Upstream_failed { host = host_text; port; detail });
              ignore_flow_error (fun () ->
                write_all
                  flow
                  (Egress_proxy_decision.response_of_decision
                     (Egress_proxy_decision.Refused
                        (Egress_proxy_decision.Upstream_unreachable
                           { host = host_text; port; detail }))))
            | Ok upstream ->
              emit (Admitted { host = host_text; port });
              ignore_flow_error (fun () ->
                write_all flow (Egress_proxy_decision.response_of_decision decision));
              (* Whatever the reader buffered past the blank line is already
                 the tunnel's first bytes -- a client that writes its head and
                 its ClientHello in one segment leaves them here. Dropping
                 them stalls the handshake; the splice below reads from the
                 flow and would never see them. *)
              ignore_flow_error (fun () ->
                let buffered = Eio.Buf_read.peek reader in
                if Cstruct.length buffered > 0
                then (
                  Eio.Flow.copy_string (Cstruct.to_string buffered) upstream;
                  Eio.Buf_read.consume reader (Cstruct.length buffered)));
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
          (* An accept that failed never reached a request, so no allowlist
             answered for it. *)
          ; rule_generation = None
          })
      (fun flow _client_addr ->
        handle_connection ~net ~clock ~keeper_name ~rules ~on_event ~read_timeout_s flow);
    accept_loop ()
  in
  accept_loop ()
;;
