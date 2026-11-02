open Alcotest

module L = Keeper_toml_loader

let doc =
  [ "keeper.name", L.Toml_string "alpha"
  ; "keeper.turns", L.Toml_int 7
  ; "keeper.temperature", L.Toml_float 0.2
  ; "keeper.enabled", L.Toml_bool true
  ; "keeper.models", L.Toml_string_array [ "fast"; "slow" ]
  ]
;;

let test_accessors () =
  check (option string) "string" (Some "alpha") (L.toml_string_opt doc "keeper.name");
  check (option int) "int" (Some 7) (L.toml_int_opt doc "keeper.turns");
  check bool "float from int"
    true
    (match L.toml_float_opt doc "keeper.turns" with
     | Some value -> Float.equal value 7.0
     | None -> false);
  check bool "bool"
    true
    (match L.toml_bool_opt doc "keeper.enabled" with
     | Some true -> true
     | _ -> false);
  check (list string) "array" [ "fast"; "slow" ]
    (L.toml_string_list doc "keeper.models")
;;

let test_update_field_in_content_preserves_table () =
  let content = "[keeper]\nname = \"old\"\n\n[other]\nname = \"keep\"\n" in
  match L.update_field_in_content ~table:"keeper" ~key:"name" ~value:"new" content with
  | Error msg -> fail msg
  | Ok updated ->
    check bool "updates target table" true
      (String.contains updated 'n'
       && String.starts_with ~prefix:"[keeper]\nname = \"new\"" updated);
    check bool "keeps other table" true
      (String.contains updated '['
       && String.ends_with ~suffix:"[other]\nname = \"keep\"\n" updated)
;;

let test_instruction_edit_preserves_string_bytes () =
  let samples =
    [ "first\nsecond"; "first\r\nsecond\r"; "control\000abcd and \027abcdef"
    ; "quotes \"\"\" and slash \\u0000abcd\n마지막 줄\n" ] in
  List.iter
    (fun instructions ->
      let content = "[keeper]\nname = \"probe\"\ninstructions = \"old\"\n" in
      let updated =
        match L.edit_keeper_fields_in_content content
          [ "instructions", L.Set (L.Toml_string instructions)
          ; "mention_targets", L.Set (L.Toml_string_array [ instructions ]) ] with
        | Ok updated -> updated
        | Error error -> fail error in
      let parsed = match L.parse_toml updated with
        | Ok parsed -> parsed
        | Error error -> fail error in
      check (option string) "saved instructions are read back exactly"
        (Some instructions) (L.toml_string_opt parsed "keeper.instructions");
      check (list string) "saved string arrays are read back exactly"
        [ instructions ] (L.toml_string_list parsed "keeper.mention_targets"))
    samples
;;

let test_unicode_escape_respects_toml_string_modes () =
  let content = {|[keeper]
instructions = """one\u0000abcd
two"""
literal = '\u0000abcd'
escaped = "\\u0000abcd"
multiline_literal = '''\u0000abcd'''
literal_line = '''first\
second'''
initial_newline = """\nfirst"""
initial_crlf = """\r\nfirst"""
quoted = """"quoted""""
# \u0000abcd is a comment, not a string
after = "\u0041bcde"
|} ^ "literal_quote = " ^ String.make 7 '\'' ^ "\n"
   ^ "literal_two_quotes = " ^ String.make 8 '\'' ^ "\n"
   ^ "basic_quote = " ^ String.make 7 '"' ^ "\n"
   ^ "basic_two_quotes = " ^ String.make 8 '"' ^ "\n" in
  let parsed = match L.parse_toml content with
    | Ok parsed -> parsed
    | Error error -> fail error in
  List.iter
    (fun (key, expected) ->
      check (option string) key (Some expected) (L.toml_string_opt parsed key))
    [ "keeper.instructions", "one\000abcd\ntwo"
    ; "keeper.literal", "\\u0000abcd"
    ; "keeper.escaped", "\\u0000abcd"
    ; "keeper.multiline_literal", "\\u0000abcd"
    ; "keeper.literal_line", "first\\\nsecond"
    ; "keeper.initial_newline", "\nfirst"
    ; "keeper.initial_crlf", "\r\nfirst"
    ; "keeper.quoted", "\"quoted\""
    ; "keeper.after", "Abcde"
    ; "keeper.literal_quote", "'"
    ; "keeper.literal_two_quotes", "''"
    ; "keeper.basic_quote", "\""
    ; "keeper.basic_two_quotes", "\"\"" ]
;;

let test_escaped_keys_keep_multiline_contents_out_of_the_editor () =
  let fixtures =
    [ {|[keeper.agent_core_env]
"AGENT_CORE_\u0041BCDE_X" = """
[keeper]
instructions = "decoy"
"""
[keeper]
instructions = "real"
|}
    ; {|[keeper."\u0061bcde"]
value = """
[keeper]
instructions = "decoy"
"""
[keeper]
instructions = "real"
|} ] in
  List.iter
    (fun content ->
      let parse text = match L.parse_toml text with
        | Ok doc -> doc | Error error -> fail error in
      let before = parse content in
      let updated = match L.update_field_in_content
          ~table:"keeper" ~key:"instructions" ~value:"NEW" content with
        | Ok updated -> updated | Error error -> fail error in
      let after = parse updated in
      check (option string) "the real instructions are changed" (Some "NEW")
        (L.toml_string_opt after "keeper.instructions");
      List.iter
        (fun (key, value) ->
          if key <> "keeper.instructions" then
            check bool "unrelated fields remain unchanged" true
              (List.assoc_opt key after = Some value))
        before)
    fixtures
;;

let test_error_line_after_initial_escape () =
  let source = "instructions = \"\"\"\\nkeep\"\"\"\nnetwork_mode = INVALID\n" in
  match L.parse_toml source with
  | Ok _ -> fail "invalid TOML was accepted"
  | Error detail ->
      check bool "error reports the original second line" true
        (String.starts_with ~prefix:"Syntax error on line 2," detail)
;;

let test_editor_newline_validation_does_not_change_manifest_reader () =
  let source = "[keeper]\ninstructions = \"first\\\n  second\"\n" in
  check bool "editor refuses a malformed single-line string" true
    (Result.is_error (L.normalize_editor_source source));
  match L.parse_toml source with
  | Error error -> fail error
  | Ok doc ->
      check (option string) "manifest reader keeps its existing behavior"
        (Some "first  second") (L.toml_string_opt doc "keeper.instructions")
;;

let with_temp_toml content f =
  let path = Filename.temp_file "keeper-toml-loader" ".toml" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Out_channel.with_open_bin path (fun channel -> output_string channel content);
      f path)
;;

let test_nested_table_edits_follow_semantic_path () =
  with_temp_toml
    "[keeper]\nname = \"probe\"\nmention_targets = [\"fs\"]\n\n[keeper.skills]\nnames = [\"old\"]\n\n[keeper.tools]\nnative = \"read\"\n"
    (fun path ->
      let edit fields =
        match L.edit_keeper_toml_fields_strict_staged ~path fields with
        | Ok () -> ()
        | Error error -> fail (Fs_compat.atomic_replace_failure_to_string error)
      in
      edit
        [ "skills.names", L.Set (L.Toml_string_array [ "ocaml-coding" ])
        ; "mention_targets", L.Set (L.Toml_string_array [ "core"; "fs" ])
        ];
      let parse label =
        let content = In_channel.with_open_bin path In_channel.input_all in
        match L.parse_toml content with
        | Ok doc -> doc
        | Error error -> failf "%s: %s" label error
      in
      let updated = parse "updated nested tables" in
      check (list string) "nested Skill updated" [ "ocaml-coding" ]
        (L.toml_string_list updated "keeper.skills.names");
      check (list string) "sibling array updated" [ "core"; "fs" ]
        (L.toml_string_list updated "keeper.mention_targets");
      check (option string) "unrelated nested tool field preserved" (Some "read")
        (L.toml_string_opt updated "keeper.tools.native");
      edit [ "skills.names", L.Remove ];
      let removed = parse "removed nested key" in
      check bool "nested Skill key removed" true
        (List.assoc_opt "keeper.skills.names" removed = None);
      check (list string) "sibling array survives removal" [ "core"; "fs" ]
        (L.toml_string_list removed "keeper.mention_targets"))
;;

let test_dotted_assignments_follow_semantic_path () =
  with_temp_toml
    "[keeper]\nskills.names = [\"old\"]\nmention_targets = [\"fs\"]\ntools.native = \"read\"\n"
    (fun path ->
      (match
         L.edit_keeper_toml_fields_strict_staged
           ~path
           [ "skills.names", L.Set (L.Toml_string_array [])
           ; "mention_targets", L.Set (L.Toml_string_array [ "core" ])
           ]
       with
       | Ok () -> ()
       | Error error -> fail (Fs_compat.atomic_replace_failure_to_string error));
      let content = In_channel.with_open_bin path In_channel.input_all in
      match L.parse_toml content with
      | Error error -> fail error
      | Ok doc ->
        check (list string) "dotted Skill updated" []
          (L.toml_string_list doc "keeper.skills.names");
        check (list string) "dotted sibling array updated" [ "core" ]
          (L.toml_string_list doc "keeper.mention_targets");
        check (option string) "dotted native posture preserved" (Some "read")
          (L.toml_string_opt doc "keeper.tools.native"))
;;

let () =
  run
    "Keeper_toml_loader"
    [ ( "accessors", [ test_case "toml accessors" `Quick test_accessors ] )
    ; ( "writer"
      , [ test_case
            "update field in target table"
            `Quick
            test_update_field_in_content_preserves_table
        ; test_case
            "nested table edits follow semantic paths"
            `Quick
            test_nested_table_edits_follow_semantic_path
        ; test_case
            "dotted assignments follow semantic paths"
            `Quick
            test_dotted_assignments_follow_semantic_path
        ; test_case
            "instructions survive saving"
            `Quick
            test_instruction_edit_preserves_string_bytes
        ; test_case
            "Unicode escapes respect TOML string modes"
            `Quick
            test_unicode_escape_respects_toml_string_modes
        ; test_case
            "escaped keys do not expose multiline contents as settings"
            `Quick
            test_escaped_keys_keep_multiline_contents_out_of_the_editor
        ; test_case
            "parse errors retain source line numbers"
            `Quick
            test_error_line_after_initial_escape
        ; test_case
            "editor validation does not change manifest parsing"
            `Quick
            test_editor_newline_validation_does_not_change_manifest_reader
        ] )
    ]
;;
