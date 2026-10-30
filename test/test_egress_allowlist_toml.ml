(* The allowlist registry as runtime.toml declares it. A rule that a resolver
   could read differently than the matcher does has to fail the load, because
   the alternative is a live allowlist with a hole in it. *)

open Alcotest

let parse content = Runtime_toml.parse_string content

let config content =
  match parse content with
  | Ok config -> config
  | Error errors ->
    failf "expected the config to load, got: %s"
      (String.concat "; " (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors))
;;

let load_errors content =
  match parse content with
  | Error errors -> String.concat "; " (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors)
  | Ok _ -> failf "expected the config to be refused, it loaded"
;;

(* Enough of a runtime.toml to load, so each case adds only its own table. *)
let base =
  {|
[providers.p]
protocol = "openai-compatible-http"
endpoint = "https://example.invalid/v1"

[models.m]

[runtime]
default = "p.m"
|}
;;

let allow_of config ~keeper_name =
  match
    Egress_allowlist.for_keeper config.Runtime_schema.egress_allowlists ~keeper_name
  with
  | Some entry -> Egress_allowlist.allow_strings entry
  | None -> failf "no allowlist entry for %s" keeper_name
;;

let test_an_allowlist_loads_and_normalizes () =
  let config =
    config
      (base
       ^ {|
[egress.keepers.alder]
allow = ["GitHub.COM", "*.GithubUserContent.com", "example.com."]
|})
  in
  check (list string) "rules are stored normalized"
    [ "github.com"; "*.githubusercontent.com"; "example.com" ]
    (allow_of config ~keeper_name:"alder")
;;

let test_a_keeper_with_no_entry_has_none () =
  let config = config base in
  check bool "the registry is empty" true
    (Egress_allowlist.for_keeper config.Runtime_schema.egress_allowlists ~keeper_name:"alder"
     = None);
  check int "and carries no entries" 0
    (List.length config.Runtime_schema.egress_allowlists)
;;

(* The load is where a bad rule has to die. *)
let test_a_rule_a_resolver_could_reread_fails_the_load () =
  let errors =
    load_errors (base ^ "\n[egress.keepers.alder]\nallow = [\"evil\\u0000.example.com\"]\n")
  in
  check bool "the refusal names the offending byte" true
    (String_util.contains_substring errors "\\x00");
  check bool "and the path" true
    (String_util.contains_substring errors "egress.keepers.alder.allow")
;;

let test_an_unknown_key_fails_the_load () =
  let errors =
    load_errors (base ^ {|
[egress.keepers.alder]
allow = ["github.com"]
deny = ["evil.com"]
|})
  in
  check bool "the unknown key is named" true (String_util.contains_substring errors "deny")
;;

let test_a_table_without_allow_fails_the_load () =
  let errors = load_errors (base ^ "\n[egress.keepers.alder]\n") in
  check bool "the missing array is named" true
    (String_util.contains_substring errors "allow")
;;

let test_an_unknown_egress_child_fails_the_load () =
  let errors = load_errors (base ^ {|
[egress.hosts]
allow = ["github.com"]
|}) in
  check bool "only [egress.keepers] is accepted" true
    (String_util.contains_substring errors "egress")
;;

(* [allow] with the wrong shape is a refusal that names the key, not an
   [Otoml.Type_error] out of the loader: [parse_file] catches only parse and
   file errors, so the exception used to take boot and hot reload down. *)
let test_a_string_allow_fails_the_load () =
  let errors = load_errors (base ^ {|
[egress.keepers.alder]
allow = "github.com"
|}) in
  check bool "the refusal names the key" true
    (String_util.contains_substring errors "egress.keepers.alder.allow");
  check bool "and the shape it wanted" true
    (String_util.contains_substring errors "an array of strings")
;;

let test_a_non_string_element_fails_the_load () =
  let errors = load_errors (base ^ {|
[egress.keepers.alder]
allow = [1]
|}) in
  check bool "the refusal names the key" true
    (String_util.contains_substring errors "egress.keepers.alder.allow")
;;

let () =
  run "egress_allowlist_toml"
    [ ( "load"
      , [ test_case "an allowlist loads and normalizes" `Quick
            test_an_allowlist_loads_and_normalizes
        ; test_case "a keeper with no entry has none" `Quick
            test_a_keeper_with_no_entry_has_none
        ] )
    ; ( "refusals"
      , [ test_case "a rule a resolver could reread fails the load" `Quick
            test_a_rule_a_resolver_could_reread_fails_the_load
        ; test_case "an unknown key fails the load" `Quick
            test_an_unknown_key_fails_the_load
        ; test_case "a table without allow fails the load" `Quick
            test_a_table_without_allow_fails_the_load
        ; test_case "an unknown egress child fails the load" `Quick
            test_an_unknown_egress_child_fails_the_load
        ; test_case "a string allow fails the load" `Quick
            test_a_string_allow_fails_the_load
        ; test_case "a non-string allow element fails the load" `Quick
            test_a_non_string_element_fails_the_load
        ] )
    ]
