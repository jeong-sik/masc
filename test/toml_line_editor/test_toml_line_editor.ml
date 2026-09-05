(* RFC-0306 §3.2 / §6 — the reason this module exists is comment preservation:
   editing a value must leave every comment, blank, and unrelated key byte-for-byte
   unchanged. These tests fix that property for the scalar and multi-line-array
   edits the fusion settings writer depends on. *)

let fixture =
  {|# top-of-file note
[fusion]
enabled = true

# panel roster doc line 1
# panel roster doc line 2
[fusion.presets.trio]
panel = [
  "provider.a",
  "provider.b",
]
# judge doc comment
judge = "old-judge"
judge_max_output_tokens = 4096
|}

let comment_lines content =
  fst (Toml_line_editor.split_lines content)
  |> List.filter (fun line ->
         let t = String.trim line in
         String.length t > 0 && Char.equal t.[0] '#')

let has_line content target =
  List.exists (String.equal target) (fst (Toml_line_editor.split_lines content))

let check_comments_unchanged before after =
  Alcotest.(check (list string))
    "every comment line survives byte-for-byte, in order"
    (comment_lines before) (comment_lines after)

let test_scalar_edit_preserves_comments () =
  let out =
    Toml_line_editor.edit_table_scalar fixture ~path:"fusion.presets.trio"
      ~key:"judge" ~value:(Some "new-judge")
  in
  check_comments_unchanged fixture out;
  Alcotest.(check bool) "judge value replaced" true
    (has_line out {|judge = "new-judge"|});
  Alcotest.(check bool) "old judge value gone" false
    (has_line out {|judge = "old-judge"|});
  Alcotest.(check bool) "unrelated scalar untouched" true
    (has_line out "judge_max_output_tokens = 4096");
  Alcotest.(check bool) "multi-line array untouched" true
    (has_line out {|  "provider.a",|})

let test_scalar_remove () =
  let out =
    Toml_line_editor.edit_table_scalar fixture ~path:"fusion.presets.trio"
      ~key:"judge" ~value:None
  in
  check_comments_unchanged fixture out;
  Alcotest.(check bool) "judge key removed" false
    (has_line out {|judge = "old-judge"|});
  Alcotest.(check bool) "sibling scalar retained" true
    (has_line out "judge_max_output_tokens = 4096")

let test_multiline_array_edit_preserves_comments () =
  let out =
    Toml_line_editor.edit_table_multiline_array fixture ~path:"fusion.presets.trio"
      ~key:"panel" ~values:[ "provider.x"; "provider.y"; "provider.z" ]
  in
  check_comments_unchanged fixture out;
  List.iter
    (fun model ->
      Alcotest.(check bool) (Printf.sprintf "new panel model %s present" model) true
        (has_line out (Printf.sprintf {|  "%s",|} model)))
    [ "provider.x"; "provider.y"; "provider.z" ];
  Alcotest.(check bool) "old panel model dropped" false
    (has_line out {|  "provider.a",|});
  Alcotest.(check bool) "array framing kept" true (has_line out "panel = [");
  Alcotest.(check bool) "sibling scalar untouched" true
    (has_line out {|judge = "old-judge"|})

(* A comment inside a multi-line array may mention a table name in brackets
   (the live runtime.toml lane blocks do). The bracket in that comment is not
   the array close: the whole old block must go, or the leftover elements and
   the real close make the file unparseable. *)
let test_multiline_array_close_ignores_bracket_in_comment () =
  let commented =
    {|[runtime.exact_output_lanes.verifier_exact]
slots = [
  "provider.a",
  # the same id lives in [runtime.lanes] too
  "provider.b",
]
next_key = 1
|}
  in
  let out =
    Toml_line_editor.edit_table_multiline_array commented
      ~path:"runtime.exact_output_lanes.verifier_exact" ~key:"slots"
      ~values:[ "provider.z" ]
  in
  Alcotest.(check bool) "old element after the comment is gone" false
    (has_line out {|  "provider.b",|});
  Alcotest.(check bool) "the comment inside the block is dropped with the block" false
    (has_line out "  # the same id lives in [runtime.lanes] too");
  Alcotest.(check int) "exactly one close bracket remains" 1
    (List.length
       (List.filter (String.equal "]") (fst (Toml_line_editor.split_lines out))));
  Alcotest.(check bool) "the key after the block survives" true
    (has_line out "next_key = 1")

(* The scalar editor must target the right table: [enabled] exists in [fusion]
   and must not be touched when editing [fusion.presets.trio]. *)
let test_scalar_edit_is_table_scoped () =
  let out =
    Toml_line_editor.edit_table_scalar fixture ~path:"fusion.presets.trio"
      ~key:"judge" ~value:(Some "new-judge")
  in
  Alcotest.(check bool) "[fusion] scalar untouched" true
    (has_line out "enabled = true")

(* ── table headers ─────────────────────────────────────────────────────── *)

let header =
  Alcotest.testable
    (fun fmt -> function
      | Toml_line_editor.Table path -> Format.fprintf fmt "[%s]" (String.concat "." path)
      | Toml_line_editor.Table_array path ->
        Format.fprintf fmt "[[%s]]" (String.concat "." path))
    (fun a b ->
      match a, b with
      | Toml_line_editor.Table x, Toml_line_editor.Table y
      | Toml_line_editor.Table_array x, Toml_line_editor.Table_array y ->
        List.equal String.equal x y
      | Toml_line_editor.Table _, Toml_line_editor.Table_array _
      | Toml_line_editor.Table_array _, Toml_line_editor.Table _ -> false)

(* The header is what the grammar reads, so every spelling TOML allows for
   one table is that table: the editor and the loader must not disagree on
   which line opens it. *)
let test_header_spellings_read_as_one_path () =
  let expected = Some (Toml_line_editor.Table [ "egress"; "keepers"; "alder" ]) in
  List.iter
    (fun line ->
      Alcotest.(check (option header)) line expected (Toml_line_editor.header_of_line line))
    [ "[egress.keepers.alder]"
    ; {|[egress.keepers."alder"]|}
    ; "[ egress . keepers . alder ]"
    ; "[egress.keepers.'alder']"
    ; "[egress.keepers.alder] # written by hand"
    ; "  [egress.keepers.alder]  "
    ]

(* A quoted segment is one key; the loader reads it the same way. *)
let test_a_quoted_dotted_key_is_one_segment () =
  Alcotest.(check (option header))
    "edgar.a.poe is one key"
    (Some (Toml_line_editor.Table [ "egress"; "keepers"; "edgar.a.poe" ]))
    (Toml_line_editor.header_of_line {|[egress.keepers."edgar.a.poe"]|})

let test_an_array_of_tables_is_told_apart () =
  Alcotest.(check (option header))
    "[[a.b]] is an array-of-tables header"
    (Some (Toml_line_editor.Table_array [ "a"; "b" ]))
    (Toml_line_editor.header_of_line "[[a.b]]");
  Alcotest.(check bool) "and still ends a section" true
    (Toml_line_editor.is_table_header "[[a.b]]");
  Alcotest.(check bool) "but is not the standard table [a.b]" false
    (Toml_line_editor.is_table ~path:"a.b" "[[a.b]]")

(* Lines that are not headers: assignments (dotted ones build a nested table
   in the same shape a header does, but the leaf is a value), inline tables,
   blanks, comments, a continuation line of a multi-line array, and a header
   with trailing content the grammar refuses. *)
let test_non_header_lines_are_none () =
  List.iter
    (fun line ->
      Alcotest.(check (option header)) (Printf.sprintf "%S" line) None
        (Toml_line_editor.header_of_line line))
    [ {|allow = ["x"]|}
    ; "a.b = 1"
    ; "a.b = {}"
    ; "a = { b = 1 }"
    ; ""
    ; "# [not.a.header] in a comment"
    ; {|  "provider.a",|}
    ; "[a.b] c = 1"
    ; "[a.b"
    ]

let test_is_table_reads_both_sides_by_path () =
  Alcotest.(check bool) "spaced and commented header opens the path" true
    (Toml_line_editor.is_table ~path:"fusion.presets.trio"
       {|[ fusion . presets . "trio" ]  # operator note|});
  Alcotest.(check bool) "a quoted path names the same table as a bare one" true
    (Toml_line_editor.is_table ~path:{|runtime.lanes."fast"|} "[runtime.lanes.fast]");
  Alcotest.(check bool) "a longer path is another table" false
    (Toml_line_editor.is_table ~path:"fusion.presets.trio" "[fusion.presets.trio.extra]");
  Alcotest.(check bool) "a name that extends the last segment is another table" false
    (Toml_line_editor.is_table ~path:"fusion.presets.trio" "[fusion.presets.trio2]")

(* The edit lands on the table however the operator spelled its header, and
   does not append a second one. *)
let test_an_edit_finds_a_hand_spelled_header () =
  let hand_spelled =
    {|[fusion]
enabled = true

[ fusion . presets . 'trio' ] # kept by hand
judge = "old-judge"

[fusion.presets.duo]
judge = "duo-judge"
|}
  in
  let out =
    Toml_line_editor.edit_table_scalar hand_spelled ~path:"fusion.presets.trio"
      ~key:"judge" ~value:(Some "new-judge")
  in
  check_comments_unchanged hand_spelled out;
  Alcotest.(check int) "one header for trio" 1
    (List.length
       (List.filter
          (Toml_line_editor.is_table ~path:"fusion.presets.trio")
          (fst (Toml_line_editor.split_lines out))));
  Alcotest.(check bool) "the hand-spelled header line is kept as written" true
    (has_line out "[ fusion . presets . 'trio' ] # kept by hand");
  Alcotest.(check bool) "judge replaced under it" true (has_line out {|judge = "new-judge"|});
  Alcotest.(check bool) "old value gone" false (has_line out {|judge = "old-judge"|});
  Alcotest.(check bool) "the next table is untouched" true
    (has_line out {|judge = "duo-judge"|})

let () =
  Alcotest.run "toml_line_editor"
    [ ( "comment-preserving edits"
      , [ Alcotest.test_case "scalar edit preserves comments" `Quick
            test_scalar_edit_preserves_comments
        ; Alcotest.test_case "scalar remove" `Quick test_scalar_remove
        ; Alcotest.test_case "multi-line array edit preserves comments" `Quick
            test_multiline_array_edit_preserves_comments
        ; Alcotest.test_case "scalar edit is table-scoped" `Quick
            test_scalar_edit_is_table_scoped
        ; Alcotest.test_case "a bracket inside a comment does not close the array" `Quick
            test_multiline_array_close_ignores_bracket_in_comment
        ] )
    ; ( "table headers"
      , [ Alcotest.test_case "header spellings read as one path" `Quick
            test_header_spellings_read_as_one_path
        ; Alcotest.test_case "a quoted dotted key is one segment" `Quick
            test_a_quoted_dotted_key_is_one_segment
        ; Alcotest.test_case "an array of tables is told apart" `Quick
            test_an_array_of_tables_is_told_apart
        ; Alcotest.test_case "non-header lines are none" `Quick
            test_non_header_lines_are_none
        ; Alcotest.test_case "is_table reads both sides by path" `Quick
            test_is_table_reads_both_sides_by_path
        ; Alcotest.test_case "an edit finds a hand-spelled header" `Quick
            test_an_edit_finds_a_hand_spelled_header
        ] )
    ]
