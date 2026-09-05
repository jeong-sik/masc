(* Writing [egress.keepers.<name>] into runtime.toml as text. The lane is
   configured in two files, and this is what lets one call write both, so the
   cases that matter are the ones where a hand edit goes wrong: a neighbour's
   table eaten, an entry that cannot be removed, a keeper name that is not a
   bare word. *)

open Alcotest

let base =
  {|[runtime]
default = "p.m"

[egress.keepers.alpha]
allow = ["api.github.com"]

[exec.ssh.endpoints.builder]
host = "builder.local"
user = "masc-exec"
remote_root = "/srv/masc/playground"
|}
;;

let parse text =
  match Runtime_toml.parse_string text with
  | Ok config -> config
  | Error errors ->
    failf "expected the result to load: %s"
      (String.concat "; "
         (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors))
;;

let allow_of text ~keeper_name =
  match
    Egress_allowlist.for_keeper
      (parse text).Runtime_schema.egress_allowlists
      ~keeper_name
  with
  | Some entry -> Egress_allowlist.allow_strings entry
  | None -> []
;;

let test_a_new_table_is_appended_and_parses () =
  let text = Runtime.update_egress_allow_text base ~keeper_name:"beta" ~allow:[ "example.com" ] in
  check (list string) "the new keeper has its allowlist" [ "example.com" ]
    (allow_of text ~keeper_name:"beta");
  check (list string) "and the existing one is untouched" [ "api.github.com" ]
    (allow_of text ~keeper_name:"alpha")
;;

(* The neighbouring table is what a naive "delete to end of file" edit eats. *)
let test_the_following_table_survives () =
  let text =
    Runtime.update_egress_allow_text base ~keeper_name:"alpha" ~allow:[ "example.com" ]
  in
  let config = parse text in
  check int "the SSH endpoint registry is still there" 1
    (List.length config.Runtime_schema.exec_ssh_endpoints);
  check (list string) "and the rewritten allowlist is the new one" [ "example.com" ]
    (allow_of text ~keeper_name:"alpha")
;;

(* Wholesale replacement, not a merge: an allowlist is the complete statement
   of what a keeper may reach, so an operator has to be able to remove an
   entry by leaving it out. *)
let test_a_rewrite_replaces_rather_than_merges () =
  let text =
    Runtime.update_egress_allow_text base ~keeper_name:"alpha"
      ~allow:[ "example.com"; "*.example.org" ]
  in
  check (list string) "the old entry is gone" [ "example.com"; "*.example.org" ]
    (allow_of text ~keeper_name:"alpha")
;;

let test_an_empty_allowlist_is_writable () =
  let text = Runtime.update_egress_allow_text base ~keeper_name:"alpha" ~allow:[] in
  check (list string) "the keeper reaches nothing" [] (allow_of text ~keeper_name:"alpha");
  check int "and the file still loads" 1
    (List.length (parse text).Runtime_schema.egress_allowlists)
;;

let test_removal_drops_only_that_table () =
  let text = Runtime.remove_egress_allow_text base ~keeper_name:"alpha" in
  check int "no allowlists remain" 0
    (List.length (parse text).Runtime_schema.egress_allowlists);
  check int "and the SSH endpoint survives" 1
    (List.length (parse text).Runtime_schema.exec_ssh_endpoints)
;;

let test_removing_an_absent_keeper_changes_nothing () =
  let text = Runtime.remove_egress_allow_text base ~keeper_name:"nobody" in
  check string "the text is unchanged apart from its trailing newline"
    (String.trim base) (String.trim text)
;;

(* A dotted keeper name is one key, not a path into a nested table. The live
   fleet has edgar.a.poe, so this is not hypothetical. *)
let test_a_dotted_keeper_name_stays_one_key () =
  let text =
    Runtime.update_egress_allow_text base ~keeper_name:"edgar.a.poe"
      ~allow:[ "api.github.com" ]
  in
  check (list string) "the dotted name round-trips" [ "api.github.com" ]
    (allow_of text ~keeper_name:"edgar.a.poe")
;;

(* The writer emits text and does not judge it; the refusal belongs to the
   load, which is also where an operator's hand edit is caught. A NUL is
   refused twice over -- the TOML lexer rejects the raw byte in a string
   before the rule matcher ever sees it, which is the earlier of the two and
   the better one. *)
let test_a_rule_that_cannot_parse_fails_the_load_not_the_write () =
  let text = Runtime.update_egress_allow_text base ~keeper_name:"alpha" ~allow:[ "evil\x00.com" ] in
  match Runtime_toml.parse_string text with
  | Ok _ -> failf "expected a NUL rule to fail the load"
  | Error errors ->
    check bool "the load refuses it and says where" true
      (List.exists
         (fun (e : Runtime_toml.parse_error) ->
           String_util.contains_substring e.message "not allowed inside a string literal")
         errors)
;;

(* One that survives TOML and dies at the matcher instead, so both refusals
   are pinned rather than only the lexer's. *)
let test_a_rule_the_matcher_refuses_fails_the_load () =
  let text = Runtime.update_egress_allow_text base ~keeper_name:"alpha" ~allow:[ "evil .com" ] in
  match Runtime_toml.parse_string text with
  | Ok _ -> failf "expected a spaced host to fail the load"
  | Error errors ->
    check bool "the matcher names the byte and the path" true
      (List.exists
         (fun (e : Runtime_toml.parse_error) ->
           String_util.contains_substring e.path "egress.keepers"
           && String_util.contains_substring e.message "not allowed in a host")
         errors)
;;

let () =
  run "egress_allow_text"
    [ ( "write"
      , [ test_case "a new table is appended and parses" `Quick
            test_a_new_table_is_appended_and_parses
        ; test_case "the following table survives" `Quick test_the_following_table_survives
        ; test_case "a rewrite replaces rather than merges" `Quick
            test_a_rewrite_replaces_rather_than_merges
        ; test_case "an empty allowlist is writable" `Quick
            test_an_empty_allowlist_is_writable
        ; test_case "a dotted keeper name stays one key" `Quick
            test_a_dotted_keeper_name_stays_one_key
        ] )
    ; ( "remove"
      , [ test_case "removal drops only that table" `Quick
            test_removal_drops_only_that_table
        ; test_case "removing an absent keeper changes nothing" `Quick
            test_removing_an_absent_keeper_changes_nothing
        ] )
    ; ( "refusals"
      , [ test_case "a rule that cannot parse fails the load not the write" `Quick
            test_a_rule_that_cannot_parse_fails_the_load_not_the_write
        ; test_case "a rule the matcher refuses fails the load" `Quick
            test_a_rule_the_matcher_refuses_fails_the_load
        ] )
    ]
