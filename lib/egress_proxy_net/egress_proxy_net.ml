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

type freshness =
  | Fresh
  | Serving_last_good

type ruleset =
  { rules : Egress_host.rule list
  ; freshness : freshness
  }

type rules_in_force =
  { generation : string
  ; freshness : freshness
  }

let rules_in_force_to_string { generation; freshness } =
  match freshness with
  | Fresh -> generation
  | Serving_last_good -> generation ^ "-stale"
;;

type event =
  { keeper_name : string
  ; at : float
  ; outcome : outcome
  ; rules_in_force : rules_in_force option
  }

(* The request line and the header block that follows it. A CONNECT authority
   that needs more than this is not a hostname, and the cap is what keeps a
   client from holding a fiber open by never sending the blank line. *)
let request_head_max_bytes = 8 * 1024
let request_head_max_headers = 128
let upstream_connect_timeout_s = 15.0
(* Every address the name resolves to, in the order the resolver gave them.
   Taking the first alone meant a host whose first record was unreachable --
   an IPv6 address on a host with no IPv6 route, a machine that is down in a
   round-robin -- failed as if the whole destination were gone, while the
   next address would have answered. *)
(** Every address an admitted destination resolves to, in resolver order.
    Exposed because this is the only place a name becomes an address, and
    that ordering -- resolve after the allowlist, never before -- is what
    keeps the matcher and the resolver from reading different names.

    All of them, not the first: a host whose first record is unreachable (an
    IPv6 address with no IPv6 route, a down machine in a round robin) would
    otherwise fail as if the destination were gone while the next address
    would have answered. *)
let resolve_upstream ~net ~host ~port =
  let name = Egress_host.to_string host in
  match Eio.Net.getaddrinfo_stream net name ~service:(string_of_int port) with
  | [] -> Error (Printf.sprintf "no address for %s" name)
  | addresses -> Ok addresses
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Printexc.to_string exn)
;;

(* Whether a failed connect says "this address did not answer" -- the only
   thing that earns trying the next one.

   Two exception types, because [Eio.Net.connect] raises both. It wraps what
   the connect itself returns into [Eio.Io], but it creates the socket
   outside that wrapping (eio 1.3, [lib_eio_posix/net.ml:149] sits above the
   [try] on 150), so a family the kernel will not serve comes back as a bare
   [Unix.Unix_error EAFNOSUPPORT]. That is exactly the case this list exists
   for: a host whose AAAA record leads on a machine with IPv6 off. Catching
   only [Eio.Io] left that one address ending the whole attempt.

   Everything else goes up. A malformed address raises [Invalid_argument],
   and moving on from that would report a code defect as an unreachable
   destination and then bury it under "no address answered". *)
let address_failed_to_answer = function
  | Eio.Cancel.Cancelled _ -> false
  | Eio.Io _ | Unix.Unix_error _ -> true
  | _ -> false
;;

let v4_shared_address_space = Ipaddr.V4.Prefix.of_string_exn "100.64.0.0/10"

let v4_reserved =
  List.map
    Ipaddr.V4.Prefix.of_string_exn
    [ "192.0.0.0/24"
    ; "192.0.2.0/24"
    ; "198.18.0.0/15"
    ; "198.51.100.0/24"
    ; "203.0.113.0/24"
    ; "240.0.0.0/4"
    ]
;;

let v6_nat64_well_known = Ipaddr.V6.Prefix.of_string_exn "64:ff9b::/96"
let v6_link_local = Ipaddr.V6.Prefix.of_string_exn "fe80::/10"
let v6_site_local = Ipaddr.V6.Prefix.of_string_exn "fec0::/10"
let v6_global_unicast = Ipaddr.V6.Prefix.of_string_exn "2000::/3"

let v6_reserved_global_unicast =
  List.map
    Ipaddr.V6.Prefix.of_string_exn
    [ "2001::/23"
    ; "2001:db8::/32"
    ; "2002::/16"
    ; "3fff::/20"
    ]
;;

let v4_refusal v4 =
  if Ipaddr.V4.Prefix.(mem v4 relative)
  then Some "unspecified address"
  else if Ipaddr.V4.Prefix.(mem v4 loopback)
  then Some "loopback address"
  else if Ipaddr.V4.Prefix.(mem v4 link)
  then Some "link-local address"
  else if List.exists (Ipaddr.V4.Prefix.mem v4) Ipaddr.V4.Prefix.private_blocks
  then Some "private-network address"
  else if Ipaddr.V4.Prefix.mem v4 v4_shared_address_space
  then Some "shared address space"
  else if Ipaddr.V4.Prefix.(mem v4 multicast)
  then Some "multicast address"
  else if List.exists (Ipaddr.V4.Prefix.mem v4) v4_reserved
  then Some "reserved address"
  else None
;;

let nat64_embedded_v4 v6 =
  Ipaddr.V4.of_octets_exn ~off:12 (Ipaddr.V6.to_octets v6)
;;

let ip_refusal = function
  | Ipaddr.V4 v4 -> v4_refusal v4
  | Ipaddr.V6 v6 ->
    (match Ipaddr.v4_of_v6 v6 with
     | Some mapped -> v4_refusal mapped
     | None ->
       if Ipaddr.V6.compare v6 Ipaddr.V6.localhost = 0
       then Some "loopback address"
       else if Ipaddr.V6.compare v6 Ipaddr.V6.unspecified = 0
       then Some "unspecified address"
       else if Ipaddr.V6.Prefix.mem v6 v6_nat64_well_known
       then v4_refusal (nat64_embedded_v4 v6)
       else if Ipaddr.V6.Prefix.mem v6 v6_link_local
       then Some "link-local address"
       else if
         Ipaddr.V6.Prefix.(mem v6 unique_local)
         || Ipaddr.V6.Prefix.mem v6 v6_site_local
       then Some "private-network address"
       else if Ipaddr.V6.Prefix.(mem v6 multicast)
       then Some "multicast address"
       else if not (Ipaddr.V6.Prefix.mem v6 v6_global_unicast)
       then Some "reserved address"
       else if List.exists (Ipaddr.V6.Prefix.mem v6) v6_reserved_global_unicast
       then Some "reserved address"
       else None)
;;

let ipaddr_of_eio ip =
  Eio.Net.Ipaddr.fold
    ~v4:(fun v4 ->
      Ipaddr.V4 (Ipaddr.V4.of_octets_exn (v4 : [ `V4 ] Eio.Net.Ipaddr.t :> string)))
    ~v6:(fun v6 ->
      Ipaddr.V6 (Ipaddr.V6.of_octets_exn (v6 : [ `V6 ] Eio.Net.Ipaddr.t :> string)))
    ip
;;

let sockaddr_refusal (addr : Eio.Net.Sockaddr.stream) =
  match addr with
  | `Unix _ -> Some "non-IP socket address"
  | `Tcp (ip, _) -> ip_refusal (ipaddr_of_eio ip)
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
         if address_failed_to_answer exn
         then attempt (Some (Printexc.to_string exn)) rest
         else
           (* A cancelled switch is the lane going away, not this address
              failing; trying the next one would outlive the reason to try.
              Anything else is a defect, and it belongs upstairs. *)
           raise exn)
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

   Cancellation is re-raised rather than swallowed. A bare wildcard catch
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

let handle_connection
      ~allow_private_ips
      ~proxy_auth
      ~net
      ~clock
      ~keeper_name
      ~rules
      ~on_event
      ~read_timeout_s
      flow
  =
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
      ; rules_in_force = !judged_by
      }
  in
  let read_request_head () =
    (* The whole request head, not just its first line. A CONNECT carries a
       header block ending in a blank line, and splicing with those still
       unread put them into the upstream stream ahead of the client's TLS
       ClientHello -- which upstream reads as a malformed handshake, on a
       schedule that depends on how the client segmented its write.

       The timeout covers reading the head, not the tunnel: a client that
       connects and says nothing must not hold the fiber, while an admitted
       tunnel is allowed to be long-lived. A head that arrived as the timeout
       expired is the head. *)
    Watched_work.run
      ~watcher:(fun () ->
        Eio.Time.sleep clock read_timeout_s;
        Error `Timeout)
      (fun () ->
         let reader = Eio.Buf_read.of_flow flow ~max_size:request_head_max_bytes in
         let request_line = Eio.Buf_read.line reader in
         let initial_bytes = String.length request_line + 2 in
         if initial_bytes > request_head_max_bytes
         then raise Eio.Buf_read.Buffer_limit_exceeded;
         let rec consume_headers ~bytes ~count acc =
           match Eio.Buf_read.line reader with
           | "" | "\r" -> List.rev acc
           | header_line ->
             let next_bytes = bytes + String.length header_line + 2 in
             let next_count = count + 1 in
             if next_bytes > request_head_max_bytes || next_count > request_head_max_headers
             then raise Eio.Buf_read.Buffer_limit_exceeded;
             consume_headers ~bytes:next_bytes ~count:next_count (header_line :: acc)
         in
         let headers = consume_headers ~bytes:initial_bytes ~count:0 [] in
         Ok (request_line, headers, reader))
  in
  match read_request_head () with
  | Error `Timeout ->
    emit (Unreadable { detail = "no request line before the read timeout" })
  | exception End_of_file -> emit (Unreadable { detail = "client closed before sending a line" })
  | exception Eio.Buf_read.Buffer_limit_exceeded ->
    emit
      (Unreadable
         { detail =
             Printf.sprintf "request head over %d bytes" request_head_max_bytes
         })
  | Ok (request_line, headers, reader) ->
    (* Asked here, per request, so an allowlist edit reaches the next
       connection instead of waiting for a lane restart. *)
    let { rules; freshness } = rules () in
    judged_by := Some { generation = Egress_host.generation rules; freshness };
    (match proxy_auth with
     | Some expected_token
       when not (Egress_proxy_decision.verify_proxy_authorization ~expected_token ~headers) ->
       let refusal = Egress_proxy_decision.Proxy_auth_required in
       emit (Refused { detail = Egress_proxy_decision.refusal_to_string refusal });
       ignore_flow_error (fun () ->
         write_all
           flow
           (Egress_proxy_decision.response_of_decision
              (Egress_proxy_decision.Refused refusal)))
     | None | Some _ ->
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
          let resolved =
            match
              Eio.Time.with_timeout clock upstream_connect_timeout_s (fun () ->
                Ok (resolve_upstream ~net ~host ~port))
            with
            | Ok res -> res
            | Error `Timeout -> Error "upstream DNS resolution timed out"
          in
          (match resolved with
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
             (match
                if allow_private_ips
                then None
                else List.find_map sockaddr_refusal addresses
              with
              | Some reason ->
                let refusal =
                  Egress_proxy_decision.Forbidden_address
                    { host = host_text; detail = reason }
                in
                emit (Refused { detail = Egress_proxy_decision.refusal_to_string refusal });
                ignore_flow_error (fun () ->
                  write_all
                    flow
                    (Egress_proxy_decision.response_of_decision
                       (Egress_proxy_decision.Refused refusal)))
              | None ->
                Eio.Switch.run (fun upstream_sw ->
                  let connected =
                    match
                      Eio.Time.with_timeout clock upstream_connect_timeout_s (fun () ->
                        Ok (connect_first_reachable ~sw:upstream_sw ~net addresses))
                    with
                    | Ok res -> res
                    | Error `Timeout -> Error "upstream connect timed out"
                  in
                  match connected with
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
                    splice ~client:flow ~upstream)))))
;;

let serve_loop
      ~allow_private_ips
      ~proxy_auth
      ~sw
      ~net
      ~clock
      ~keeper_name
      ~rules
      ~on_event
      ~socket
      ~read_timeout_s
  =
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
          ; rules_in_force = None
          })
      (fun flow _client_addr ->
        handle_connection
          ~allow_private_ips
          ~proxy_auth
          ~net
          ~clock
          ~keeper_name
          ~rules
          ~on_event
          ~read_timeout_s
          flow);
    accept_loop ()
  in
  accept_loop ()
;;

let serve ~proxy_auth ~sw ~net ~clock ~keeper_name ~rules ~on_event ~socket ~read_timeout_s =
  serve_loop
    ~allow_private_ips:false
    ~proxy_auth
    ~sw
    ~net
    ~clock
    ~keeper_name
    ~rules
    ~on_event
    ~socket
    ~read_timeout_s
;;

module For_testing = struct
  let address_failed_to_answer = address_failed_to_answer

  let ip_refusal_of_string raw =
    match Ipaddr.of_string raw with
    | Ok ip -> ip_refusal ip
    | Error (`Msg detail) -> invalid_arg detail
  ;;

  let serve_allowing_private_ips
        ~proxy_auth
        ~sw
        ~net
        ~clock
        ~keeper_name
        ~rules
        ~on_event
        ~socket
        ~read_timeout_s
    =
    serve_loop
      ~allow_private_ips:true
      ~proxy_auth
      ~sw
      ~net
      ~clock
      ~keeper_name
      ~rules
      ~on_event
      ~socket
      ~read_timeout_s
  ;;
end
