(* The allowlist matcher is the trust boundary, so the cases that matter are
   the ones that got a real sandbox bypassed rather than the ones that spell
   a hostname correctly. *)

open Alcotest
module H = Egress_host

let parses raw =
  match H.parse raw with
  | Ok host -> H.to_string host
  | Error error -> failf "expected %S to parse, got %s" raw (H.parse_error_to_string error)
;;

let refuses raw =
  match H.parse raw with
  | Error error -> H.parse_error_to_string error
  | Ok host -> failf "expected %S to be refused, it parsed as %S" raw (H.to_string host)
;;

let rule raw =
  match H.rule_of_string raw with
  | Ok rule -> rule
  | Error error -> failf "rule %S did not parse: %s" raw (H.parse_error_to_string error)
;;

let host raw =
  match H.parse raw with
  | Ok host -> host
  | Error error -> failf "host %S did not parse: %s" raw (H.parse_error_to_string error)
;;

let admits ?(port = H.default_rule_port) rules raw =
  H.admits (List.map rule rules) (host raw) ~port
;;

(* The bypass this module exists for. sandbox-runtime <= 0.0.42 compared the
   whole byte string with endsWith, so this passed a *.google.com allowlist
   while getaddrinfo stopped at the NUL and resolved the attacker's host. *)
let test_a_nul_byte_never_reaches_the_matcher () =
  let raw = "attacker-host.com\x00.google.com" in
  check bool "the NUL is named, not matched" true
    (match H.parse raw with
     | Error (H.Forbidden_byte { byte = '\x00'; _ }) -> true
     | Error _ | Ok _ -> false);
  check string "and the message escapes it"
    "byte \\x00 at offset 17 is not allowed in a host"
    (refuses raw)
;;

let test_the_other_bytes_that_split_parsers () =
  List.iter
    (fun (raw, label) ->
      check bool label true
        (match H.parse raw with
         | Error (H.Forbidden_byte _) -> true
         | Error _ | Ok _ -> false))
    [ "evil.com%00.example.com", "percent is refused"
    ; "evil.com\r\n.example.com", "CRLF is refused"
    ; "evil.com\t.example.com", "tab is refused"
    ; "evil.com .example.com", "space is refused"
    ; "evil.com/.example.com", "slash is refused"
    ; "evil.com:443", "colon is refused"
    ; "evil.com@example.com", "at is refused"
    ; "[::1]", "an IPv6 literal is refused rather than read as a name"
    ]
;;

(* A suffix check on the string would admit this; a suffix check on labels
   does not, because notexample.com shares no label boundary with
   example.com. *)
let test_a_sibling_name_is_not_a_subdomain () =
  check bool "notexample.com is refused by *.example.com" false
    (admits [ "*.example.com" ] "notexample.com");
  check bool "evil-example.com is refused" false
    (admits [ "*.example.com" ] "evil-example.com");
  check bool "example.com.evil.com is refused" false
    (admits [ "*.example.com" ] "example.com.evil.com")
;;

let test_a_wildcard_is_strictly_below_its_apex () =
  check bool "api.example.com is admitted" true
    (admits [ "*.example.com" ] "api.example.com");
  check bool "deep.api.example.com is admitted" true
    (admits [ "*.example.com" ] "deep.api.example.com");
  check bool "the apex itself is not" false (admits [ "*.example.com" ] "example.com")
;;

(* A destination is a host and a port, so a rule has to be able to say the
   port. Pinning one meant an operator with a service on 8443 could not use
   the lane at all. *)
let test_a_rule_carries_its_port () =
  check int "an unqualified rule means 443" 443 (H.rule_port (rule "example.com"));
  check int "and a qualified one means what it says" 8443
    (H.rule_port (rule "example.com:8443"));
  check bool "the qualified rule admits its own port" true
    (admits ~port:8443 [ "example.com:8443" ] "example.com");
  check bool "and refuses 443" false (admits ~port:443 [ "example.com:8443" ] "example.com");
  check bool "an unqualified rule refuses another port" false
    (admits ~port:8443 [ "example.com" ] "example.com");
  check bool "a wildcard carries a port too" true
    (admits ~port:8443 [ "*.example.com:8443" ] "api.example.com")
;;

let test_a_host_can_be_named_on_two_ports () =
  let rules = [ "example.com"; "example.com:8443" ] in
  check bool "443 is admitted" true (admits ~port:443 rules "example.com");
  check bool "8443 is admitted" true (admits ~port:8443 rules "example.com");
  check bool "9443 is not" false (admits ~port:9443 rules "example.com");
  check (list int) "and the permitted ports can be named" [ 443; 8443 ]
    (H.ports_for_host (List.map rule rules) (host "example.com"))
;;

(* So a refusal can tell "not permitted" from "permitted on another port".
   The two are different operator mistakes. *)
let test_a_host_is_recognized_apart_from_its_port () =
  let rules = List.map rule [ "example.com:8443" ] in
  check bool "the host is recognized" true (H.admits_host rules (host "example.com"));
  check bool "an unnamed host is not" false (H.admits_host rules (host "evil.com"));
  check (list int) "and its port is reported" [ 8443 ]
    (H.ports_for_host rules (host "example.com"))
;;

(* A colon that is not a port leaves the host holding one, and a host with a
   colon is refused -- which is where that refusal belongs. The byte named is
   whichever the scan reaches first, so the assertion is that the rule is
   refused as an unusable host, not which byte did it. *)
let test_a_colon_that_is_not_a_port_still_refuses () =
  List.iter
    (fun raw ->
      check bool (raw ^ " is refused") true
        (match H.rule_of_string raw with
         | Error (H.Forbidden_byte _) -> true
         | Error _ | Ok _ -> false))
    [ "example.com:https"; "example.com:0"; "example.com:70000"; "[::1]:443" ]
;;

let test_an_exact_rule_is_exact () =
  check bool "the same name is admitted" true (admits [ "example.com" ] "example.com");
  check bool "a subdomain is not" false (admits [ "example.com" ] "api.example.com");
  check bool "a parent is not" false (admits [ "api.example.com" ] "example.com")
;;

(* A name rule must never answer for an address: an allowlist of github.com
   is not permission to open a socket to github's IP. *)
let test_a_name_rule_never_admits_an_address () =
  check bool "the address is parsed as an address" true (H.is_ip_literal (host "140.82.121.6"));
  check bool "github.com does not admit it" false (admits [ "github.com" ] "140.82.121.6");
  check bool "*.com does not admit it" false (admits [ "*.com" ] "140.82.121.6");
  check bool "the address admits itself" true
    (admits [ "140.82.121.6" ] "140.82.121.6");
  check bool "and not a different one" false (admits [ "140.82.121.6" ] "1.1.1.1")
;;

let test_an_address_rule_never_admits_a_name () =
  check bool "an address rule refuses a name" false
    (admits [ "140.82.121.6" ] "github.com")
;;

let test_case_and_the_absolute_form_normalize () =
  check string "case folds" "api.example.com" (parses "API.Example.COM");
  check string "one trailing dot is the same name" "example.com" (parses "example.com.");
  check bool "and it still matches" true (admits [ "example.com" ] "EXAMPLE.com.");
  check bool "two trailing dots are an empty label" true
    (match H.parse "example.com.." with
     | Error (H.Empty_label _) -> true
     | Error _ | Ok _ -> false)
;;

let test_the_shape_rules () =
  check bool "empty is refused" true
    (match H.parse "" with Error H.Empty -> true | Error _ | Ok _ -> false);
  check bool "a leading dot is an empty label" true
    (match H.parse ".example.com" with
     | Error (H.Empty_label { position = 0 }) -> true
     | Error _ | Ok _ -> false);
  check bool "a doubled dot is an empty label" true
    (match H.parse "a..b" with
     | Error (H.Empty_label _) -> true
     | Error _ | Ok _ -> false);
  check bool "a 64-byte label is refused" true
    (match H.parse (String.make 64 'a' ^ ".com") with
     | Error (H.Label_too_long { bytes = 64; _ }) -> true
     | Error _ | Ok _ -> false);
  check bool "a 63-byte label is fine" true
    (match H.parse (String.make 63 'a' ^ ".com") with Ok _ -> true | Error _ -> false);
  check bool "a leading hyphen is refused" true
    (match H.parse "-evil.com" with
     | Error (H.Label_edge_hyphen _) -> true
     | Error _ | Ok _ -> false);
  check bool "an inner hyphen is fine" true
    (match H.parse "my-host.com" with Ok _ -> true | Error _ -> false);
  check bool "over 253 bytes is refused" true
    (let long = String.concat "." (List.init 40 (fun _ -> String.make 8 'a')) in
     match H.parse long with
     | Error (H.Too_long _) -> true
     | Error _ | Ok _ -> false)
;;

(* A keeper whose allowlist parsed to nothing reaches nothing. The opposite
   default is how an allowlist quietly stops being one. *)
let test_an_empty_allowlist_admits_nothing () =
  check bool "nothing is admitted" false (admits [] "example.com");
  check bool "not even an address" false (admits [] "1.1.1.1")
;;

let test_a_rule_a_resolver_could_reread_is_refused_at_load () =
  check bool "a NUL in a rule is refused" true
    (match H.rule_of_string "evil\x00.example.com" with
     | Error (H.Forbidden_byte _) -> true
     | Error _ | Ok _ -> false);
  check bool "a NUL in a wildcard apex is refused" true
    (match H.rule_of_string "*.evil\x00.example.com" with
     | Error (H.Forbidden_byte _) -> true
     | Error _ | Ok _ -> false);
  check bool "a bare star is not a wildcard rule" true
    (match H.rule_of_string "*" with
     | Error (H.Forbidden_byte { byte = '*'; _ }) -> true
     | Error _ | Ok _ -> false)
;;

let test_rules_round_trip_their_spelling () =
  check string "an exact rule" "example.com" (H.rule_to_string (rule "Example.COM"));
  check string "a wildcard rule" "*.example.com" (H.rule_to_string (rule "*.Example.COM"))
;;

(* Rules are read per request, so the record of a decision has to say which
   allowlist made it. These pin what "the same rules" means. *)

let gen entries = H.generation (List.map rule entries)

let test_the_same_rules_are_the_same_generation () =
  check string
    "order does not make a different policy"
    (gen [ "github.com"; "*.githubusercontent.com"; "api.anthropic.com:443" ])
    (gen [ "api.anthropic.com"; "github.com"; "*.githubusercontent.com" ]);
  check string
    "neither does a repeat"
    (gen [ "github.com" ])
    (gen [ "github.com"; "github.com" ]);
  check string
    "nor a spelling the parser normalizes"
    (gen [ "github.com" ])
    (gen [ "GitHub.com." ])
;;

let test_an_edit_moves_the_generation () =
  let before = gen [ "github.com" ] in
  check bool "adding a host" true (before <> gen [ "github.com"; "pypi.org" ]);
  check bool "removing one" true (before <> gen []);
  (* The port is part of what a rule permits, so a rule that moved to another
     port is a different rule and must not read as the same policy. *)
  check bool "moving the port" true (before <> gen [ "github.com:8443" ]);
  check bool "widening to a wildcard" true (before <> gen [ "*.github.com" ])
;;

let test_the_generation_is_short_and_printable () =
  let value = gen [ "github.com"; "*.example.com:8443" ] in
  check int "eight characters" 8 (String.length value);
  check bool
    "hex, so it survives any log format"
    true
    (String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
       value);
  (* An empty allowlist reaches nothing, which is a policy like any other and
     needs a name in the record. *)
  check int "an empty allowlist still has one" 8 (String.length (gen []))
;;

let generation_cases =
  [ test_case "the same rules are the same generation" `Quick
      test_the_same_rules_are_the_same_generation
  ; test_case "an edit moves the generation" `Quick test_an_edit_moves_the_generation
  ; test_case "the generation is short and printable" `Quick
      test_the_generation_is_short_and_printable
  ]
;;

let () =
  run "egress_host"
    [ ( "bypasses"
      , [ test_case "a NUL byte never reaches the matcher" `Quick
            test_a_nul_byte_never_reaches_the_matcher
        ; test_case "the other bytes that split parsers" `Quick
            test_the_other_bytes_that_split_parsers
        ; test_case "a sibling name is not a subdomain" `Quick
            test_a_sibling_name_is_not_a_subdomain
        ; test_case "a rule a resolver could reread is refused at load" `Quick
            test_a_rule_a_resolver_could_reread_is_refused_at_load
        ] )
    ; ( "matching"
      , [ test_case "a wildcard is strictly below its apex" `Quick
            test_a_wildcard_is_strictly_below_its_apex
        ; test_case "an exact rule is exact" `Quick test_an_exact_rule_is_exact
        ; test_case "a rule carries its port" `Quick test_a_rule_carries_its_port
        ; test_case "a host can be named on two ports" `Quick
            test_a_host_can_be_named_on_two_ports
        ; test_case "a host is recognized apart from its port" `Quick
            test_a_host_is_recognized_apart_from_its_port
        ; test_case "a colon that is not a port still refuses" `Quick
            test_a_colon_that_is_not_a_port_still_refuses
        ; test_case "a name rule never admits an address" `Quick
            test_a_name_rule_never_admits_an_address
        ; test_case "an address rule never admits a name" `Quick
            test_an_address_rule_never_admits_a_name
        ; test_case "an empty allowlist admits nothing" `Quick
            test_an_empty_allowlist_admits_nothing
        ] )
    ; ( "shape"
      , [ test_case "case and the absolute form normalize" `Quick
            test_case_and_the_absolute_form_normalize
        ; test_case "the shape rules" `Quick test_the_shape_rules
        ; test_case "rules round trip their spelling" `Quick
            test_rules_round_trip_their_spelling
        ] )
    ; "generation", generation_cases
    ]
