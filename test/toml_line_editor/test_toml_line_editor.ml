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

(* ── array-of-tables entries ───────────────────────────────────────────── *)

(* Endpoint lists are array-of-tables, and adding or removing one entry is the
   whole job of a voice setup wizard. This fixture mirrors what a live
   runtime.toml carries: an operator's measured notes above the first entry
   header, two entries, and a section after them. *)
let endpoints_fixture =
  {|[voice.stt]
default_model = "scribe_v2"

# 2026-09-03: local whisper goes first. Measured 0.85 s on a real utterance.
# model=scribe_v2 is ignored by whisper, and leaving api_key_env out is what
# keeps the Authorization header absent, which is why this answers 200.

[[voice.stt.endpoints]]
id = "whisper-local"
kind = "openai_compat"
base_url = "http://127.0.0.1:2022/v1"
enabled = true
timeout_seconds = 60.0

[[voice.stt.endpoints]]
id = "elevenlabs-stt"
kind = "elevenlabs_direct"
api_key_env = "ELEVENLABS_API_KEY"
enabled = true
timeout_seconds = 35.0


[voice.session]
endpoints = []
|}

let lines_of content = fst (Toml_line_editor.split_lines content)

let count_line content target =
  List.length (List.filter (String.equal target) (lines_of content))

let index_of content target =
  match Toml_line_editor.find_index (String.equal target) (lines_of content) with
  | Some index -> index
  | None -> Alcotest.failf "line not found: %s" target

let upsert = Toml_line_editor.upsert_table_array_entry
let endpoints = "voice.stt.endpoints"

let test_entry_ids_read_in_file_order () =
  Alcotest.(check (list string))
    "both endpoints, in the order the file lists them"
    [ "whisper-local"; "elevenlabs-stt" ]
    (Toml_line_editor.table_array_entry_ids endpoints_fixture ~path:endpoints ~id_key:"id")

let test_upsert_edits_only_the_addressed_entry () =
  let out =
    upsert endpoints_fixture ~path:endpoints ~id_key:"id" ~id:"whisper-local"
      ~fields:[ "base_url", Toml_line_editor.String "http://127.0.0.1:9000/v1" ]
  in
  check_comments_unchanged endpoints_fixture out;
  Alcotest.(check bool) "the addressed entry took the new value" true
    (has_line out {|base_url = "http://127.0.0.1:9000/v1"|});
  Alcotest.(check bool) "the old value is gone" false
    (has_line out {|base_url = "http://127.0.0.1:2022/v1"|});
  Alcotest.(check bool) "the sibling entry is untouched" true
    (has_line out {|api_key_env = "ELEVENLABS_API_KEY"|});
  Alcotest.(check bool) "and keeps its own timeout" true
    (has_line out "timeout_seconds = 35.0")

(* A float that renders as [35] loads as an integer, and a field declared float
   is then refused by type -- which is exactly the shape of the bug that kept
   voice silent for six days. *)
let test_a_float_field_keeps_its_point () =
  let out =
    upsert endpoints_fixture ~path:endpoints ~id_key:"id" ~id:"whisper-local"
      ~fields:[ "timeout_seconds", Toml_line_editor.Float 35.0 ]
  in
  Alcotest.(check bool) "35.0 does not render as a bare 35" true
    (has_line out "timeout_seconds = 35.0")

let test_a_bool_field_is_not_quoted () =
  let out =
    upsert endpoints_fixture ~path:endpoints ~id_key:"id" ~id:"whisper-local"
      ~fields:[ "enabled", Toml_line_editor.Bool false ]
  in
  Alcotest.(check bool) "enabled reads as a bool" true (has_line out "enabled = false");
  Alcotest.(check bool) "not as a string" false (has_line out {|enabled = "false"|})

let test_a_field_the_entry_lacks_is_appended_to_it_alone () =
  let out =
    upsert endpoints_fixture ~path:endpoints ~id_key:"id" ~id:"whisper-local"
      ~fields:[ "health_url", Toml_line_editor.String "http://127.0.0.1:2022/health" ]
  in
  Alcotest.(check int) "the new field is written exactly once" 1
    (count_line out {|health_url = "http://127.0.0.1:2022/health"|});
  Alcotest.(check bool) "it lands inside the addressed entry, before the next header" true
    (index_of out {|health_url = "http://127.0.0.1:2022/health"|}
     < index_of out {|id = "elevenlabs-stt"|})

let test_a_new_entry_lands_after_the_last_one () =
  let out =
    upsert endpoints_fixture ~path:endpoints ~id_key:"id" ~id:"mlx-audio"
      ~fields:
        [ "kind", Toml_line_editor.String "openai_compat"
        ; "base_url", Toml_line_editor.String "http://127.0.0.1:8000/v1"
        ; "enabled", Toml_line_editor.Bool true
        ; "timeout_seconds", Toml_line_editor.Float 60.0
        ]
  in
  check_comments_unchanged endpoints_fixture out;
  Alcotest.(check bool) "it sits after the last existing endpoint" true
    (index_of out {|id = "elevenlabs-stt"|} < index_of out {|id = "mlx-audio"|});
  Alcotest.(check bool) "and before the section that follows them" true
    (index_of out {|id = "mlx-audio"|} < index_of out "[voice.session]");
  Alcotest.(check int) "one header is added, not two" 3
    (List.length (lines_of out |> List.filter (Toml_line_editor.is_table_array ~path:endpoints)));
  Alcotest.(check (list string)) "all three are addressable afterwards"
    [ "whisper-local"; "elevenlabs-stt"; "mlx-audio" ]
    (Toml_line_editor.table_array_entry_ids out ~path:endpoints ~id_key:"id")

let test_upsert_with_no_entries_yet_appends_one () =
  let source = {|[voice.tts]
default_model = "eleven_multilingual_v2"
|} in
  let out =
    upsert source ~path:"voice.tts.endpoints" ~id_key:"id" ~id:"elevenlabs-direct"
      ~fields:[ "kind", Toml_line_editor.String "elevenlabs_direct" ]
  in
  Alcotest.(check (list string)) "the entry is addressable" [ "elevenlabs-direct" ]
    (Toml_line_editor.table_array_entry_ids out ~path:"voice.tts.endpoints" ~id_key:"id");
  Alcotest.(check bool) "the existing table survives" true
    (has_line out {|default_model = "eleven_multilingual_v2"|})

(* [id] is the entry's identity. A second spelling of it in the field list could
   disagree with the entry the call just addressed. *)
let test_an_id_inside_fields_is_ignored () =
  let out =
    upsert endpoints_fixture ~path:endpoints ~id_key:"id" ~id:"whisper-local"
      ~fields:
        [ "id", Toml_line_editor.String "renamed"; "enabled", Toml_line_editor.Bool false ]
  in
  Alcotest.(check bool) "the id stays as addressed" true
    (has_line out {|id = "whisper-local"|});
  Alcotest.(check bool) "the rename never lands" false (has_line out {|id = "renamed"|});
  Alcotest.(check bool) "the other field still applies" true (has_line out "enabled = false")

let test_remove_drops_the_entry_and_its_fields () =
  let out =
    Toml_line_editor.remove_table_array_entry endpoints_fixture ~path:endpoints
      ~id_key:"id" ~id:"whisper-local"
  in
  Alcotest.(check (list string)) "only the sibling remains" [ "elevenlabs-stt" ]
    (Toml_line_editor.table_array_entry_ids out ~path:endpoints ~id_key:"id");
  Alcotest.(check bool) "its fields went with it" false
    (has_line out {|base_url = "http://127.0.0.1:2022/v1"|});
  Alcotest.(check bool) "the section after the entries survives" true
    (has_line out "[voice.session]")

(* The notes above a header were written by an operator about the endpoint, and
   nothing in the text says where that block begins. Swallowing them would
   delete the measured reason the setting exists. *)
let test_remove_keeps_the_notes_written_above_the_header () =
  let out =
    Toml_line_editor.remove_table_array_entry endpoints_fixture ~path:endpoints
      ~id_key:"id" ~id:"whisper-local"
  in
  check_comments_unchanged endpoints_fixture out

let test_removing_an_absent_id_changes_nothing () =
  let out =
    Toml_line_editor.remove_table_array_entry endpoints_fixture ~path:endpoints
      ~id_key:"id" ~id:"never-configured"
  in
  Alcotest.(check (list string)) "both entries stay" [ "whisper-local"; "elevenlabs-stt" ]
    (Toml_line_editor.table_array_entry_ids out ~path:endpoints ~id_key:"id");
  check_comments_unchanged endpoints_fixture out

(* [a.b] and [[a.b]] carry the same path and mean different things to a loader,
   so an editor that confused them would write a field into the wrong shape. *)
let test_a_table_and_a_table_array_of_one_path_stay_apart () =
  Alcotest.(check bool) "[[a.b]] is not the standard table [a.b]" false
    (Toml_line_editor.is_table ~path:endpoints "[[voice.stt.endpoints]]");
  Alcotest.(check bool) "[[a.b]] is the table array" true
    (Toml_line_editor.is_table_array ~path:endpoints "[[voice.stt.endpoints]]");
  Alcotest.(check bool) "[a.b] is not the table array" false
    (Toml_line_editor.is_table_array ~path:endpoints "[voice.stt.endpoints]")

let test_an_entry_without_the_id_key_is_skipped () =
  let source = {|[[voice.stt.endpoints]]
kind = "openai_compat"

[[voice.stt.endpoints]]
id = "named"
|} in
  Alcotest.(check (list string)) "only the entry that names itself is listed" [ "named" ]
    (Toml_line_editor.table_array_entry_ids source ~path:endpoints ~id_key:"id")

let test_a_value_line_renders_each_type () =
  let render key value = Toml_line_editor.value_line ~key ~value in
  Alcotest.(check string) "string" {|id = "a"|} (render "id" (Toml_line_editor.String "a"));
  Alcotest.(check string) "int" "port = 8000" (render "port" (Toml_line_editor.Int 8000));
  Alcotest.(check string) "bool" "enabled = true" (render "enabled" (Toml_line_editor.Bool true));
  Alcotest.(check string) "a whole float keeps a point" "t = 35.0"
    (render "t" (Toml_line_editor.Float 35.0));
  Alcotest.(check string) "a fractional float is not padded out" "t = 0.5"
    (render "t" (Toml_line_editor.Float 0.5))

(* Found by running the editor against a live 2000-line runtime.toml while every
   fixture case above was passing: adding an entry put its separating blank line
   above it, and removing an entry takes the blanks below it, so each add/remove
   round trip left one blank line behind and a wizard that added and dropped an
   endpoint a few times grew the file. *)
let test_add_then_remove_restores_the_file () =
  let added =
    upsert endpoints_fixture ~path:endpoints ~id_key:"id" ~id:"mlx-audio"
      ~fields:
        [ "kind", Toml_line_editor.String "openai_compat"
        ; "base_url", Toml_line_editor.String "http://127.0.0.1:8000/v1"
        ]
  in
  let back =
    Toml_line_editor.remove_table_array_entry added ~path:endpoints ~id_key:"id"
      ~id:"mlx-audio"
  in
  Alcotest.(check string) "the file comes back byte-for-byte" endpoints_fixture back

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
    ; ( "array-of-tables entries"
      , [ Alcotest.test_case "entry ids read in file order" `Quick
            test_entry_ids_read_in_file_order
        ; Alcotest.test_case "upsert edits only the addressed entry" `Quick
            test_upsert_edits_only_the_addressed_entry
        ; Alcotest.test_case "a float field keeps its point" `Quick
            test_a_float_field_keeps_its_point
        ; Alcotest.test_case "a bool field is not quoted" `Quick
            test_a_bool_field_is_not_quoted
        ; Alcotest.test_case "a missing field is appended to that entry alone" `Quick
            test_a_field_the_entry_lacks_is_appended_to_it_alone
        ; Alcotest.test_case "a new entry lands after the last one" `Quick
            test_a_new_entry_lands_after_the_last_one
        ; Alcotest.test_case "upsert with no entries yet appends one" `Quick
            test_upsert_with_no_entries_yet_appends_one
        ; Alcotest.test_case "an id inside fields is ignored" `Quick
            test_an_id_inside_fields_is_ignored
        ; Alcotest.test_case "remove drops the entry and its fields" `Quick
            test_remove_drops_the_entry_and_its_fields
        ; Alcotest.test_case "remove keeps the notes above the header" `Quick
            test_remove_keeps_the_notes_written_above_the_header
        ; Alcotest.test_case "removing an absent id changes nothing" `Quick
            test_removing_an_absent_id_changes_nothing
        ; Alcotest.test_case "a table and a table array of one path stay apart" `Quick
            test_a_table_and_a_table_array_of_one_path_stay_apart
        ; Alcotest.test_case "an entry without the id key is skipped" `Quick
            test_an_entry_without_the_id_key_is_skipped
        ; Alcotest.test_case "a value line renders each type" `Quick
            test_a_value_line_renders_each_type
        ; Alcotest.test_case "add then remove restores the file" `Quick
            test_add_then_remove_restores_the_file
        ] )
    ]
