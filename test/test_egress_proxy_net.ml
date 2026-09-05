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

(* A record of "admitted" that cannot say which allowlist admitted it is not
   evidence. The rules are re-read per request, so an operator's edit between
   two connections is otherwise invisible in the log. *)
let test_an_event_names_the_rules_that_judged_it () =
  let allow = [ "github.com" ] in
  let _, events = one_request ~allow ~line:"CONNECT github.com:443 HTTP/1.1" in
  match events with
  | [ event ] ->
    check
      (option string)
      "the generation is the one those rules hash to"
      (Some (Egress_host.generation (rules allow)))
      event.Egress_proxy_net.rule_generation;
    (* A refusal is a decision too, and tracing one back to its rules is how
       an operator tells "I never allowed that" from "I allowed it and then
       stopped". *)
    let _, refused = one_request ~allow ~line:"CONNECT evil.com:443 HTTP/1.1" in
    (match refused with
     | [ refusal ] ->
       check
         (option string)
         "a refusal carries it too"
         (Some (Egress_host.generation (rules allow)))
         refusal.Egress_proxy_net.rule_generation
     | other -> failf "expected one refusal event, got %d" (List.length other))
  | other -> failf "expected one event, got %d" (List.length other)
;;

let test_an_edited_allowlist_shows_as_a_new_generation () =
  let before =
    match snd (one_request ~allow:[ "github.com" ] ~line:"CONNECT github.com:443 HTTP/1.1") with
    | [ event ] -> event.Egress_proxy_net.rule_generation
    | other -> failf "expected one event, got %d" (List.length other)
  in
  let after =
    match
      snd
        (one_request
           ~allow:[ "github.com"; "pypi.org" ]
           ~line:"CONNECT github.com:443 HTTP/1.1")
    with
    | [ event ] -> event.Egress_proxy_net.rule_generation
    | other -> failf "expected one event, got %d" (List.length other)
  in
  check bool "the same request under different rules reads differently" true
    (before <> after);
  check bool "and both actually have one" true
    (Option.is_some before && Option.is_some after)
;;

(* How long a lane takes to stop while a tunnel is still open.

   This is the defect the review found by reading: [serve] forks each
   connection onto the switch it is handed, so handing it the lane's own
   switch left the handlers alive after [Fiber.first] cancelled the accept
   loop, and the enclosing [Switch.run] then joined on them. A keeper's
   shutdown waited on somebody else's connection.

   Both shapes are measured, because "the fix works" means nothing beside no
   number. [give_serve_its_own_switch:false] is the old wiring, kept only for
   that comparison. *)
(* The fixed wiring stops in about 0.03s, measured. The ceiling is fifty
   times that, so a loaded machine does not turn this into a flake, and the
   old wiring's branch -- which never stops -- costs the suite this much
   every run. That cost is the price of the assertion having two sides. *)
let stop_latency_ceiling_s = 1.5

let stop_latency_with_a_tunnel_open ~give_serve_its_own_switch =
  let lane_finished = ref None in
  Eio_main.run (fun env ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    Eio.Switch.run (fun harness_sw ->
      (* An upstream that accepts and holds. Neither end closes, which is
         what an ordinary long-lived connection looks like. *)
      let upstream =
        Eio.Net.listen net ~sw:harness_sw ~reuse_addr:true ~backlog:4
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
      in
      let upstream_port = port_of upstream in
      Eio.Fiber.fork ~sw:harness_sw (fun () ->
        try
          Eio.Net.accept_fork ~sw:harness_sw upstream ~on_error:(fun _ -> ())
            (fun flow _ ->
               ignore
                 (Eio.Buf_read.line (Eio.Buf_read.of_flow flow ~max_size:64) : string))
        with _ -> ());
      (* Bound by the caller, as the lane does it: binding is how the caller
         learns which port the guest must be pointed at. *)
      let socket =
        Eio.Net.listen net ~sw:harness_sw ~reuse_addr:true ~backlog:4
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
      in
      let proxy_port = port_of socket in
      let stop, resolve_stop = Eio.Promise.create () in
      let started = ref 0.0 in
      ignore
        (Eio.Time.with_timeout clock stop_latency_ceiling_s (fun () ->
           Eio.Fiber.both
             (fun () ->
                (* The lane, in the shape keeper_keepalive runs it. *)
                Eio.Switch.run (fun proxy_sw ->
                  Eio.Fiber.first
                    (fun () ->
                       let run_serve serve_sw =
                         Egress_proxy_net.serve
                           ~sw:serve_sw
                           ~net
                           ~clock
                           ~keeper_name:"stoplatency"
                           ~rules:(fun () ->
                             rules [ Printf.sprintf "127.0.0.1:%d" upstream_port ])
                           ~on_event:(fun _ -> ())
                           ~socket
                           ~read_timeout_s:5.0
                       in
                       if give_serve_its_own_switch
                       then Eio.Switch.run (fun serve_sw -> run_serve serve_sw)
                       else run_serve proxy_sw)
                    (fun () -> Eio.Promise.await stop));
                lane_finished := Some (Eio.Time.now clock -. !started))
             (fun () ->
                let flow =
                  Eio.Net.connect ~sw:harness_sw net
                    (`Tcp (Eio.Net.Ipaddr.V4.loopback, proxy_port))
                in
                Eio.Flow.copy_string
                  (Printf.sprintf "CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n" upstream_port)
                  flow;
                let reader = Eio.Buf_read.of_flow flow ~max_size:65536 in
                (* Status line then the blank line. Past this the tunnel is
                   open and nothing closes it. *)
                let _status = Eio.Buf_read.line reader in
                let _blank = Eio.Buf_read.line reader in
                started := Eio.Time.now clock;
                Eio.Promise.resolve resolve_stop ());
           Ok ())
         : (unit, [ `Timeout ]) result);
      (* The harness switch holds the client and the upstream. Releasing it
         here rather than earlier is what keeps the tunnel open across the
         stop. *)
      ()));
  !lane_finished
;;

(* The lane must stop while a tunnel is open, and the old wiring must be seen
   not to. A one-sided assertion here would pass against the defect. *)
let test_a_stop_does_not_wait_on_an_open_tunnel () =
  match stop_latency_with_a_tunnel_open ~give_serve_its_own_switch:true with
  | None ->
    failf "the lane did not stop within %.1fs with a tunnel open" stop_latency_ceiling_s
  | Some seconds ->
    check bool
      (Printf.sprintf "stopped in %.3fs, under the %.1fs ceiling" seconds
         stop_latency_ceiling_s)
      true
      (seconds < stop_latency_ceiling_s);
    (* Serving on the lane's own switch is the defect. If this ever stops
       too, the two shapes are no longer different and this test has stopped
       proving anything. *)
    check
      (option (float 0.001))
      "the old wiring does not stop at all"
      None
      (stop_latency_with_a_tunnel_open ~give_serve_its_own_switch:false)
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
        ; test_case "an event names the rules that judged it" `Quick
            test_an_event_names_the_rules_that_judged_it
        ; test_case "an edited allowlist shows as a new generation" `Quick
            test_an_edited_allowlist_shows_as_a_new_generation
        ; test_case "a stop does not wait on an open tunnel" `Quick
            test_a_stop_does_not_wait_on_an_open_tunnel
        ] )
    ]
