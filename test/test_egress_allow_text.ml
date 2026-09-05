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

(* A keeper's table is found by what the grammar reads out of its header,
   not by how the header is spelled. The writer quotes the key; an operator's
   hand may not, may space the brackets, may single-quote, may leave a note
   on the line. Each of these is one keeper, so a rewrite lands on that table
   and a removal takes exactly that table. *)
let alder_header_spellings =
  [ "quoted", {|[egress.keepers."alder"]|}
  ; "unquoted", "[egress.keepers.alder]"
  ; "spaced brackets and dots", "[ egress . keepers . alder ]"
  ; "single-quoted", "[egress.keepers.'alder']"
  ; "trailing comment", "[egress.keepers.alder] # written by hand"
  ]
;;

(* alder2 sits after alder so that a match on the name as a prefix, or a
   section end that overshoots, shows up as a change to alder2. *)
let two_keepers ~alder_header =
  String.concat
    "\n"
    [ "[runtime]"
    ; {|default = "p.m"|}
    ; ""
    ; alder_header
    ; {|allow = ["api.github.com"]|}
    ; ""
    ; "[egress.keepers.alder2]"
    ; {|allow = ["alder2.example"]|}
    ; ""
    ; "[exec.ssh.endpoints.builder]"
    ; {|host = "builder.local"|}
    ; {|user = "masc-exec"|}
    ; {|remote_root = "/srv/masc/playground"|}
    ; ""
    ]
;;

(* Line numbers of the standard-table headers that open [keeper_name]'s
   table, read the way the loader reads them. In place means the list is the
   same before and after; not appended means it has one entry. *)
let header_lines text ~keeper_name =
  fst (Toml_line_editor.split_lines text)
  |> List.mapi (fun index line -> index, Toml_line_editor.header_of_line line)
  |> List.filter_map (fun (index, header) ->
    match header with
    | Some (Toml_line_editor.Table path)
      when List.equal String.equal path [ "egress"; "keepers"; keeper_name ] -> Some index
    | Some (Toml_line_editor.Table _ | Toml_line_editor.Table_array _) | None -> None)
;;

let test_a_rewrite_lands_on_the_table_however_it_is_spelled () =
  List.iter
    (fun (label, alder_header) ->
      let base = two_keepers ~alder_header in
      let text =
        Runtime.update_egress_allow_text base ~keeper_name:"alder" ~allow:[ "example.com" ]
      in
      check (list int) (label ^ ": one table for alder, where it was")
        (header_lines base ~keeper_name:"alder")
        (header_lines text ~keeper_name:"alder");
      check (list string) (label ^ ": and it holds the new allowlist") [ "example.com" ]
        (allow_of text ~keeper_name:"alder");
      check (list string) (label ^ ": alder2 is untouched") [ "alder2.example" ]
        (allow_of text ~keeper_name:"alder2");
      check int (label ^ ": the SSH endpoint survives") 1
        (List.length (parse text).Runtime_schema.exec_ssh_endpoints))
    alder_header_spellings
;;

let test_removal_takes_the_table_however_it_is_spelled () =
  List.iter
    (fun (label, alder_header) ->
      let base = two_keepers ~alder_header in
      let text = Runtime.remove_egress_allow_text base ~keeper_name:"alder" in
      check (list int) (label ^ ": no table for alder") [] (header_lines text ~keeper_name:"alder");
      check (list string) (label ^ ": alder2 keeps its allowlist") [ "alder2.example" ]
        (allow_of text ~keeper_name:"alder2");
      check int (label ^ ": alder2 is the only allowlist left") 1
        (List.length (parse text).Runtime_schema.egress_allowlists);
      check int (label ^ ": the SSH endpoint survives") 1
        (List.length (parse text).Runtime_schema.exec_ssh_endpoints))
    alder_header_spellings
;;

(* The other direction of the prefix: alder2's table is alder2's, whichever
   spelling alder's header has in front of it. *)
let test_a_name_that_extends_another_is_its_own_keeper () =
  List.iter
    (fun (label, alder_header) ->
      let base = two_keepers ~alder_header in
      let rewritten =
        Runtime.update_egress_allow_text base ~keeper_name:"alder2" ~allow:[ "example.org" ]
      in
      check (list int) (label ^ ": alder2 is rewritten where it was")
        (header_lines base ~keeper_name:"alder2")
        (header_lines rewritten ~keeper_name:"alder2");
      check (list string) (label ^ ": alder keeps its allowlist") [ "api.github.com" ]
        (allow_of rewritten ~keeper_name:"alder");
      let removed = Runtime.remove_egress_allow_text base ~keeper_name:"alder2" in
      check (list int) (label ^ ": alder2 is gone") [] (header_lines removed ~keeper_name:"alder2");
      check (list string) (label ^ ": and alder still has its allowlist") [ "api.github.com" ]
        (allow_of removed ~keeper_name:"alder"))
    alder_header_spellings
;;

(* A dotted name is quoted by the writer and by the loader's reading of the
   file, so an existing quoted-dotted header is that keeper's table too. *)
let test_a_dotted_name_header_is_rewritten_in_place () =
  let base = two_keepers ~alder_header:{|[egress.keepers."edgar.a.poe"]|} in
  let text =
    Runtime.update_egress_allow_text base ~keeper_name:"edgar.a.poe" ~allow:[ "example.com" ]
  in
  check (list int) "one table for edgar.a.poe, where it was"
    (header_lines base ~keeper_name:"edgar.a.poe")
    (header_lines text ~keeper_name:"edgar.a.poe");
  check (list string) "holding the new allowlist" [ "example.com" ]
    (allow_of text ~keeper_name:"edgar.a.poe");
  let removed = Runtime.remove_egress_allow_text base ~keeper_name:"edgar.a.poe" in
  check (list int) "and removal takes it" [] (header_lines removed ~keeper_name:"edgar.a.poe");
  check (list string) "leaving alder2" [ "alder2.example" ] (allow_of removed ~keeper_name:"alder2")
;;

(* The loader refuses an array of tables as a keeper, so the writer does not
   take [[egress.keepers.alder]] for alder's table either: the line stays as
   the boundary it is, the table is added after it, and the load names the
   clash rather than picking one of the two. *)
let test_an_array_of_tables_is_not_the_keepers_table () =
  let array_header = "[[egress.keepers.alder]]" in
  let base = two_keepers ~alder_header:array_header in
  let text =
    Runtime.update_egress_allow_text base ~keeper_name:"alder" ~allow:[ "example.com" ]
  in
  check bool "the array-of-tables line is left where it was" true
    (List.mem array_header (fst (Toml_line_editor.split_lines text)));
  check int "and one standard table was added for alder" 1
    (List.length (header_lines text ~keeper_name:"alder"));
  match Runtime_toml.parse_string text with
  | Ok _ -> failf "expected the load to refuse two definitions of one keeper"
  | Error errors ->
    check bool "the load names the clash" true
      (List.exists
         (fun (e : Runtime_toml.parse_error) ->
           String_util.contains_substring e.message "egress.keepers.alder")
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
    ; ( "header spellings"
      , [ test_case "a rewrite lands on the table however it is spelled" `Quick
            test_a_rewrite_lands_on_the_table_however_it_is_spelled
        ; test_case "removal takes the table however it is spelled" `Quick
            test_removal_takes_the_table_however_it_is_spelled
        ; test_case "a name that extends another is its own keeper" `Quick
            test_a_name_that_extends_another_is_its_own_keeper
        ; test_case "a dotted name header is rewritten in place" `Quick
            test_a_dotted_name_header_is_rewritten_in_place
        ; test_case "an array of tables is not the keeper's table" `Quick
            test_an_array_of_tables_is_not_the_keepers_table
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
