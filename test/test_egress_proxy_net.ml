(* The proxy with a real socket under it, driving the real [serve]. The
   decision is covered without a socket in test_egress_proxy_decision; what
   this suite adds is that the bytes and the events follow the decision --
   a refused request must not open a tunnel, and every request produces
   exactly one event. *)

open Alcotest

let rules raws =
  List.map
    (fun raw ->
      match Egress_host.rule_of_string raw with
      | Ok rule -> rule
      | Error error ->
        failf "rule %S did not parse: %s" raw (Egress_host.parse_error_to_string error))
    raws
;;

let port_of socket =
  match Eio.Net.listening_addr socket with
  | `Tcp (_, port) -> port
  | `Unix _ -> failwith "expected a TCP listener"
;;

(* One request against a proxy serving [allow], and the events it produced.
   The switch is released as soon as the answer is read, which is what stops
   the accept loop. *)
let one_request ~allow ~line =
  let collected = ref [] in
  let status = ref "" in
  (try
     Eio_main.run (fun env ->
       Eio.Switch.run (fun sw ->
         let net = Eio.Stdenv.net env in
         let clock = Eio.Stdenv.clock env in
         let socket =
           Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:4
             (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
         in
         let port = port_of socket in
         Eio.Fiber.fork ~sw (fun () ->
           try
             Egress_proxy_net.serve
               ~sw
               ~net
               ~clock
               ~keeper_name:"probe"
               ~rules:(fun () -> rules allow)
               ~on_event:(fun event -> collected := event :: !collected)
               ~socket
               ~read_timeout_s:5.0
           with _ -> ());
         let flow = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
         Eio.Flow.copy_string (line ^ "\r\n\r\n") flow;
         let reader = Eio.Buf_read.of_flow flow ~max_size:65536 in
         (status := try Eio.Buf_read.line reader with End_of_file -> "");
         raise Exit))
   with
   | Exit -> ());
  !status, List.rev !collected
;;

(* An admitted request has to actually carry bytes, and nothing pinned that
   until a rule could name a port: a stub upstream binds an ephemeral one, so
   with the port fixed at 443 there was no destination a test could both
   allow and reach. Splicing two flows is exactly the part a refusal test
   cannot check.

   The stub greets, then echoes one line, so a one-way copy is
   distinguishable from a real splice. *)
let admitted_tunnel_exchange ~request =
  let events = ref [] in
  let greeting = "UPSTREAM-HELLO" in
  let transcript = ref [] in
  (try
     Eio_main.run (fun env ->
       Eio.Switch.run (fun sw ->
         let net = Eio.Stdenv.net env in
         let clock = Eio.Stdenv.clock env in
         let upstream =
           Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:4
             (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
         in
         let upstream_port = port_of upstream in
         Eio.Fiber.fork ~sw (fun () ->
           try
             Eio.Net.accept_fork ~sw upstream ~on_error:(fun _ -> ()) (fun flow _ ->
               Eio.Flow.copy_string (greeting ^ "\n") flow;
               let reader = Eio.Buf_read.of_flow flow ~max_size:4096 in
               match Eio.Buf_read.line reader with
               | line -> Eio.Flow.copy_string ("echo:" ^ line ^ "\n") flow
               | exception End_of_file -> ())
           with _ -> ());
         let proxy =
           Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:4
             (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
         in
         let proxy_port = port_of proxy in
         Eio.Fiber.fork ~sw (fun () ->
           try
             Egress_proxy_net.serve
               ~sw
               ~net
               ~clock
               ~keeper_name:"tunnel"
               ~rules:(fun () -> rules [ Printf.sprintf "127.0.0.1:%d" upstream_port ])
               ~on_event:(fun event -> events := event :: !events)
               ~socket:proxy
               ~read_timeout_s:5.0
           with _ -> ());
         let flow = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, proxy_port)) in
         Eio.Flow.copy_string
           (Printf.sprintf "CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n" upstream_port)
           flow;
         let reader = Eio.Buf_read.of_flow flow ~max_size:65536 in
         let read_line () = try Some (Eio.Buf_read.line reader) with End_of_file -> None in
         (* Status line, then the blank line ending the proxy's headers, then
            the upstream's own greeting -- which only arrives if the splice
            runs. *)
         let lines = List.filter_map (fun () -> read_line ()) [ (); (); () ] in
         Eio.Flow.copy_string (request ^ "\n") flow;
         let echoed = read_line () in
         transcript := lines @ (match echoed with None -> [] | Some line -> [ line ]);
         raise Exit))
   with
   | Exit -> ());
  !transcript, List.rev !events
;;

let test_an_admitted_request_tunnels_both_ways () =
  let transcript, events = admitted_tunnel_exchange ~request:"PING" in
  check bool "the tunnel is opened with a 200" true
    (match transcript with
     | status :: _ -> String_util.contains_substring status "200"
     | [] -> false);
  check bool "the upstream's own greeting arrives through it" true
    (List.exists (fun line -> String_util.contains_substring line "UPSTREAM-HELLO") transcript);
  check bool "and what the client sent came back, so both directions carry" true
    (List.exists (fun line -> String_util.contains_substring line "echo:PING") transcript);
  check bool "recorded as admitted, not as an upstream failure" true
    (match events with
     | [ { Egress_proxy_net.outcome = Egress_proxy_net.Admitted _; _ } ] -> true
     | _ -> false)
;;

(* The allowlist is asked per request, so an operator's edit reaches the next
   connection. Nothing here restarts: the same listener answers both, and the
   thunk returns something different the second time. *)
let test_a_changed_allowlist_applies_to_the_next_request () =
  let answers = ref [] in
  let generation = ref 0 in
  (try
     Eio_main.run (fun env ->
       Eio.Switch.run (fun sw ->
         let net = Eio.Stdenv.net env in
         let clock = Eio.Stdenv.clock env in
         let socket =
           Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:4
             (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
         in
         let port = port_of socket in
         Eio.Fiber.fork ~sw (fun () ->
           try
             Egress_proxy_net.serve
               ~sw
               ~net
               ~clock
               ~keeper_name:"reload"
               ~rules:(fun () ->
                 (* First request: example.com is allowed. Second: it is not. *)
                 incr generation;
                 if !generation = 1 then rules [ "example.com" ] else rules [ "other.test" ])
               ~on_event:(fun _ -> ())
               ~socket
               ~read_timeout_s:5.0
           with _ -> ());
         let ask () =
           let flow =
             Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
           in
           Eio.Flow.copy_string "CONNECT example.com:443 HTTP/1.1\r\n\r\n" flow;
           let reader = Eio.Buf_read.of_flow flow ~max_size:65536 in
           let status = try Eio.Buf_read.line reader with End_of_file -> "" in
           (try Eio.Flow.shutdown flow `Send with _ -> ());
           status
         in
         let first = ask () in
         let second = ask () in
         answers := [ first; second ];
         raise Exit))
   with
   | Exit -> ());
  match !answers with
  | [ first; second ] ->
    (* The first is admitted, or fails reaching a real upstream -- either way
       it is not a 403, which is what says the allowlist admitted it. *)
    check bool "the first request is not refused" false
      (String.length first >= 12 && String.equal (String.sub first 0 12) "HTTP/1.1 403");
    check bool "the second is, with no restart in between" true
      (String.length second >= 12 && String.equal (String.sub second 0 12) "HTTP/1.1 403")
  | _ -> failf "expected two answers, got %d" (List.length !answers)
;;

let is_403 status =
  String.length status >= 12 && String.equal (String.sub status 0 12) "HTTP/1.1 403"
;;

let single_refusal = function
  | [ { Egress_proxy_net.outcome = Egress_proxy_net.Refused _; _ } ] -> true
  | _ -> false
;;

let test_a_refused_request_gets_403_and_no_tunnel () =
  let status, events = one_request ~allow:[ "example.com" ] ~line:"CONNECT evil.com:443 HTTP/1.1" in
  check bool "the status is 403" true (is_403 status);
  check int "exactly one event" 1 (List.length events);
  check bool "and it is a refusal" true (single_refusal events)
;;

let test_a_malformed_line_is_refused_without_a_tunnel () =
  let status, events =
    one_request ~allow:[ "example.com" ] ~line:"GET http://example.com/ HTTP/1.1"
  in
  check bool "the status is 403" true (is_403 status);
  check bool "one refusal event" true (single_refusal events)
;;

(* The bypass, end to end: the NUL never reaches a resolver, because the
   request never becomes an admitted destination. An Upstream_failed here
   would mean the name had been handed to getaddrinfo. *)
let test_a_nul_authority_never_opens_a_tunnel () =
  let status, events =
    one_request
      ~allow:[ "*.google.com" ]
      ~line:"CONNECT attacker.com\x00.google.com:443 HTTP/1.1"
  in
  check bool "the status is 403" true (is_403 status);
  check bool "recorded as a refusal, not an upstream failure" true (single_refusal events)
;;

let test_a_port_outside_the_lane_is_refused () =
  let status, events =
    one_request ~allow:[ "example.com" ] ~line:"CONNECT example.com:22 HTTP/1.1"
  in
  check bool "the status is 403" true (is_403 status);
  check bool "one refusal event" true (single_refusal events)
;;

let test_every_request_produces_one_event_naming_its_keeper () =
  let _status, events =
    one_request ~allow:[] ~line:"CONNECT anything.example:443 HTTP/1.1"
  in
  check int "one event for one request" 1 (List.length events);
  check string "and it names the keeper" "probe"
    (match events with
     | [ event ] -> event.Egress_proxy_net.keeper_name
     | _ -> "none")
;;

let () =
  run "egress_proxy_net"
    [ ( "refusals"
      , [ test_case "a refused request gets 403 and no tunnel" `Quick
            test_a_refused_request_gets_403_and_no_tunnel
        ; test_case "a malformed line is refused without a tunnel" `Quick
            test_a_malformed_line_is_refused_without_a_tunnel
        ; test_case "a NUL authority never opens a tunnel" `Quick
            test_a_nul_authority_never_opens_a_tunnel
        ; test_case "a port outside the lane is refused" `Quick
            test_a_port_outside_the_lane_is_refused
        ] )
    ; ( "reload"
      , [ test_case "a changed allowlist applies to the next request" `Quick
            test_a_changed_allowlist_applies_to_the_next_request
        ] )
    ; ( "tunnel"
      , [ test_case "an admitted request tunnels both ways" `Quick
            test_an_admitted_request_tunnels_both_ways
        ] )
    ; ( "evidence"
      , [ test_case "every request produces one event naming its keeper" `Quick
            test_every_request_produces_one_event_naming_its_keeper
        ] )
    ]
