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
               ~rules:(rules allow)
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
    ; ( "evidence"
      , [ test_case "every request produces one event naming its keeper" `Quick
            test_every_request_produces_one_event_naming_its_keeper
        ] )
    ]
