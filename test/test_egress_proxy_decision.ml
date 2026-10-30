(* The proxy's decision, exercised without a socket. The cases are the ones
   that would let a request past the allowlist, not the ones that spell
   CONNECT correctly. *)

open Alcotest
module D = Egress_proxy_decision

let rules raws =
  List.map
    (fun raw ->
      match Egress_host.rule_of_string raw with
      | Ok rule -> rule
      | Error error ->
        failf "rule %S did not parse: %s" raw (Egress_host.parse_error_to_string error))
    raws
;;

let decide allow line = D.decide ~rules:(rules allow) ~request_line:line

let admitted allow line =
  match decide allow line with
  | D.Admitted { host; port } -> Egress_host.to_string host, port
  | D.Refused refusal -> failf "expected %S to be admitted, got %s" line (D.refusal_to_string refusal)
;;

let refusal allow line =
  match decide allow line with
  | D.Refused refusal -> refusal
  | D.Admitted { host; port } ->
    failf "expected %S to be refused, it was admitted as %s:%d" line
      (Egress_host.to_string host) port
;;

let is_not_in_allowlist = function D.Not_in_allowlist _ -> true | _ -> false
let is_unparsable = function D.Unparsable_host _ -> true | _ -> false
let is_malformed = function D.Malformed_request _ -> true | _ -> false

let test_an_allowed_destination_is_admitted () =
  check (pair string int) "host and port come through"
    ("api.github.com", 443)
    (admitted [ "api.github.com" ] "CONNECT api.github.com:443 HTTP/1.1");
  check (pair string int) "a wildcard admits a subdomain"
    ("api.github.com", 443)
    (admitted [ "*.github.com" ] "CONNECT api.github.com:443 HTTP/1.1")
;;

let test_a_destination_outside_the_allowlist_is_refused () =
  check bool "an unlisted host is refused" true
    (is_not_in_allowlist (refusal [ "github.com" ] "CONNECT evil.com:443 HTTP/1.1"));
  check bool "an empty allowlist refuses everything" true
    (is_not_in_allowlist (refusal [] "CONNECT github.com:443 HTTP/1.1"))
;;

(* The bypass class, at the proxy's own boundary this time: the authority is
   parsed by Egress_host before anything resolves it, so a NUL never reaches
   a matcher and never reaches getaddrinfo either. *)
let test_a_nul_in_the_authority_is_refused () =
  check bool "the NUL is refused as an unparsable host" true
    (is_unparsable
       (refusal [ "*.google.com" ] "CONNECT attacker-host.com\x00.google.com:443 HTTP/1.1"))
;;

let test_a_sibling_name_cannot_ride_a_wildcard () =
  check bool "notgithub.com is refused by *.github.com" true
    (is_not_in_allowlist (refusal [ "*.github.com" ] "CONNECT notgithub.com:443 HTTP/1.1"))
;;

(* An allowlist of names is not permission to open a socket to an address,
   so an address has to be listed as itself. *)
let test_an_address_needs_its_own_rule () =
  check bool "a name rule does not admit the address" true
    (is_not_in_allowlist (refusal [ "github.com" ] "CONNECT 140.82.121.6:443 HTTP/1.1"));
  check (pair string int) "an address rule admits it"
    ("140.82.121.6", 443)
    (admitted [ "140.82.121.6" ] "CONNECT 140.82.121.6:443 HTTP/1.1")
;;

(* A rule says which port it permits, so the port is the allowlist's answer
   rather than a constant this module holds. *)
let test_the_port_comes_from_the_rule () =
  check (pair string int) "a rule can name another port"
    ("registry.internal", 8443)
    (admitted [ "registry.internal:8443" ] "CONNECT registry.internal:8443 HTTP/1.1");
  check bool "and then 443 is refused" true
    (match refusal [ "registry.internal:8443" ] "CONNECT registry.internal:443 HTTP/1.1" with
     | D.Port_not_allowed { port = 443; allowed = [ 8443 ]; _ } -> true
     | _ -> false);
  check bool "an unqualified rule means 443 only" true
    (match refusal [ "github.com" ] "CONNECT github.com:80 HTTP/1.1" with
     | D.Port_not_allowed { port = 80; allowed = [ 443 ]; _ } -> true
     | _ -> false)
;;

(* A host on the wrong port and a host nobody listed are different operator
   mistakes, fixed in different places, so the refusal keeps them apart and
   names the ports that would have worked. *)
let test_a_wrong_port_is_not_an_unlisted_host () =
  check bool "a listed host on a wrong port says so" true
    (match refusal [ "*.github.com" ] "CONNECT api.github.com:22 HTTP/1.1" with
     | D.Port_not_allowed { host = "api.github.com"; port = 22; allowed = [ 443 ] } -> true
     | _ -> false);
  check bool "an unlisted host stays an allowlist miss" true
    (is_not_in_allowlist (refusal [ "*.github.com" ] "CONNECT evil.com:22 HTTP/1.1"));
  check bool "and the message names the permitted port" true
    (String_util.contains_substring
       (D.refusal_to_string (refusal [ "github.com" ] "CONNECT github.com:80 HTTP/1.1"))
       "443")
;;

let test_the_request_line_is_parsed_strictly () =
  List.iter
    (fun (line, label) ->
      check bool label true (is_malformed (refusal [ "github.com" ] line)))
    [ "GET http://github.com/ HTTP/1.1", "a non-CONNECT verb is refused"
    ; "CONNECT github.com:443", "a missing version is refused"
    ; "CONNECT github.com:443 HTTP/2", "an unsupported version is refused"
    ; "CONNECT github.com HTTP/1.1", "a missing port is refused"
    ; "CONNECT github.com:https HTTP/1.1", "a non-numeric port is refused"
    ; "CONNECT github.com:0 HTTP/1.1", "port zero is refused"
    ; "CONNECT github.com:70000 HTTP/1.1", "an out-of-range port is refused"
    ; "CONNECT  github.com:443 HTTP/1.1", "a doubled space is refused"
    ; "", "an empty line is refused"
    ]
;;

let test_a_trailing_cr_is_the_terminator_not_the_host () =
  check (pair string int) "the CR does not reach the host parser"
    ("github.com", 443)
    (admitted [ "github.com" ] "CONNECT github.com:443 HTTP/1.1\r")
;;

let test_the_response_says_what_happened () =
  check string "an admitted request opens the tunnel"
    "HTTP/1.1 200 Connection Established\r\n\r\n"
    (D.response_of_decision (decide [ "github.com" ] "CONNECT github.com:443 HTTP/1.1"));
  let refused =
    D.response_of_decision (decide [ "github.com" ] "CONNECT evil.com:443 HTTP/1.1")
  in
  check bool "a refused request is a 403" true
    (String.length refused > 12 && String.sub refused 0 12 = "HTTP/1.1 403");
  check bool "and the body names the host" true
    (String_util.contains_substring refused "evil.com");
  check bool "the refusal carries no raw request bytes" false
    (String_util.contains_substring refused "CONNECT")
;;

let test_a_refusal_never_echoes_the_offending_byte_raw () =
  let refused =
    D.response_of_decision
      (decide [ "*.google.com" ] "CONNECT attacker.com\x00.google.com:443 HTTP/1.1")
  in
  check bool "the NUL is escaped" true (String_util.contains_substring refused "\\x00");
  check bool "and not present raw" false (String.exists (Char.equal '\x00') refused)
;;

(* An admitted destination that will not connect is not the client's fault.
   403 says "you may not"; 502 says "what you asked for did not answer", and
   answering the second with the first sends an operator to the allowlist for
   a problem that is not there. *)
let test_an_unreachable_upstream_is_502_not_403 () =
  let refusal =
    D.Upstream_unreachable
      { host = "api.github.com"; port = 443; detail = "Connection refused" }
  in
  let response = D.response_of_decision (D.Refused refusal) in
  check bool "the status is 502" true
    (String.length response >= 12
     && String.equal (String.sub response 0 12) "HTTP/1.1 502");
  check bool "and it names the destination, not the request" true
    (String_util.contains_substring response "api.github.com:443");
  check bool "a policy refusal is still 403" true
    (let policy = D.response_of_decision (decide [ "github.com" ] "CONNECT evil.com:443 HTTP/1.1") in
     String.length policy >= 12 && String.equal (String.sub policy 0 12) "HTTP/1.1 403")
;;

let () =
  run "egress_proxy_decision"
    [ ( "allowlist"
      , [ test_case "an allowed destination is admitted" `Quick
            test_an_allowed_destination_is_admitted
        ; test_case "a destination outside the allowlist is refused" `Quick
            test_a_destination_outside_the_allowlist_is_refused
        ; test_case "a sibling name cannot ride a wildcard" `Quick
            test_a_sibling_name_cannot_ride_a_wildcard
        ; test_case "an address needs its own rule" `Quick
            test_an_address_needs_its_own_rule
        ] )
    ; ( "bypasses"
      , [ test_case "a NUL in the authority is refused" `Quick
            test_a_nul_in_the_authority_is_refused
        ; test_case "a refusal never echoes the offending byte raw" `Quick
            test_a_refusal_never_echoes_the_offending_byte_raw
        ] )
    ; ( "protocol"
      , [ test_case "an unreachable upstream is 502 not 403" `Quick
            test_an_unreachable_upstream_is_502_not_403
        ; test_case "the port comes from the rule" `Quick test_the_port_comes_from_the_rule
        ; test_case "a wrong port is not an unlisted host" `Quick
            test_a_wrong_port_is_not_an_unlisted_host
        ; test_case "the request line is parsed strictly" `Quick
            test_the_request_line_is_parsed_strictly
        ; test_case "a trailing CR is the terminator not the host" `Quick
            test_a_trailing_cr_is_the_terminator_not_the_host
        ; test_case "the response says what happened" `Quick
            test_the_response_says_what_happened
        ] )
    ]
