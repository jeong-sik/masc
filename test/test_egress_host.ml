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

let admits rules raw = H.admits (List.map rule rules) (host raw)

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
    ]
