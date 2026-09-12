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

let upsert content ~path ~id_key ~id ~fields =
  match Toml_line_editor.upsert_table_array_entry content ~path ~id_key ~id ~fields with
  | Ok updated -> updated
  | Error error ->
    Alcotest.failf "upsert refused: %s" (Toml_line_editor.entry_error_message error)
let endpoints = "voice.stt.endpoints"

let test_entry_ids_read_in_file_order () =
  Alcotest.(check (list string))
    "both endpoints, in the order the file lists them"
    [ "whisper-local"; "elevenlabs-stt" ]
    (Toml_line_editor.table_array_entry_ids endpoints_fixture ~path:endpoints ~id_key:"id")

let test_upsert_edits_only_the_addressed_entry () =
  let out =
    upsert endpoints_fixture ~path:endpoints ~id_key:"id" ~id:"whisper-local"
      ~fields:[ "base_url", Some (Toml_line_editor.String "http://127.0.0.1:9000/v1") ]
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
      ~fields:[ "timeout_seconds", Some (Toml_line_editor.Float 35.0) ]
  in
  Alcotest.(check bool) "35.0 does not render as a bare 35" true
    (has_line out "timeout_seconds = 35.0")

let test_a_bool_field_is_not_quoted () =
  let out =
    upsert endpoints_fixture ~path:endpoints ~id_key:"id" ~id:"whisper-local"
      ~fields:[ "enabled", Some (Toml_line_editor.Bool false) ]
  in
  Alcotest.(check bool) "enabled reads as a bool" true (has_line out "enabled = false");
  Alcotest.(check bool) "not as a string" false (has_line out {|enabled = "false"|})

let test_a_field_the_entry_lacks_is_appended_to_it_alone () =
  let out =
    upsert endpoints_fixture ~path:endpoints ~id_key:"id" ~id:"whisper-local"
      ~fields:[ "health_url", Some (Toml_line_editor.String "http://127.0.0.1:2022/health") ]
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
        [ "kind", Some (Toml_line_editor.String "openai_compat")
        ; "base_url", Some (Toml_line_editor.String "http://127.0.0.1:8000/v1")
        ; "enabled", Some (Toml_line_editor.Bool true)
        ; "timeout_seconds", Some (Toml_line_editor.Float 60.0)
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
      ~fields:[ "kind", Some (Toml_line_editor.String "elevenlabs_direct") ]
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
        [ "id", Some (Toml_line_editor.String "renamed"); "enabled", Some (Toml_line_editor.Bool false) ]
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
        [ "kind", Some (Toml_line_editor.String "openai_compat")
        ; "base_url", Some (Toml_line_editor.String "http://127.0.0.1:8000/v1")
        ]
  in
  let back =
    Toml_line_editor.remove_table_array_entry added ~path:endpoints ~id_key:"id"
      ~id:"mlx-audio"
  in
  Alcotest.(check string) "the file comes back byte-for-byte" endpoints_fixture back

let count_key content key =
  lines_of content
  |> List.filter (fun line ->
       match Toml_line_editor.key_of_line line with
       | Some found -> String.equal found key
       | None -> false)
  |> List.length

(* Switching an endpoint from a hosted provider to a local one has to drop
   api_key_env. Left behind it sends an Authorization header the local server
   never asked for, and the endpoint answers 401 instead of serving. *)
let test_a_none_field_is_dropped_from_the_entry () =
  let out =
    upsert endpoints_fixture ~path:endpoints ~id_key:"id" ~id:"elevenlabs-stt"
      ~fields:
        [ "api_key_env", None
        ; "base_url", Some (Toml_line_editor.String "http://127.0.0.1:8000/v1")
        ]
  in
  Alcotest.(check bool) "the dropped key is gone" false
    (has_line out {|api_key_env = "ELEVENLABS_API_KEY"|});
  Alcotest.(check bool) "the field set in the same call landed" true
    (has_line out {|base_url = "http://127.0.0.1:8000/v1"|});
  Alcotest.(check bool) "the sibling entry keeps its own base_url" true
    (has_line out {|base_url = "http://127.0.0.1:2022/v1"|});
  check_comments_unchanged endpoints_fixture out

let test_a_new_entry_skips_its_none_fields () =
  let out =
    upsert endpoints_fixture ~path:endpoints ~id_key:"id" ~id:"local-tts"
      ~fields:
        [ "kind", Some (Toml_line_editor.String "openai_compat"); "api_key_env", None ]
  in
  Alcotest.(check bool) "the field that has a value is written" true
    (has_line out {|kind = "openai_compat"|});
  Alcotest.(check int) "only the pre-existing api_key_env line is in the file" 1
    (count_key out "api_key_env")

let test_dropping_a_field_the_entry_lacks_changes_nothing () =
  let out =
    upsert endpoints_fixture ~path:endpoints ~id_key:"id" ~id:"whisper-local"
      ~fields:[ "default_voice", None ]
  in
  Alcotest.(check string) "the file is untouched" endpoints_fixture out

(* ── what a line editor must not get wrong ─────────────────────────────── *)

(* Every case below was measured against this module by an adversarial review
   while the suite above was green. The verdict is the loader's, not a line
   count: a line editor that produces text TOML refuses has failed, and one that
   produces text TOML accepts but that means something else has failed worse. *)

let check_loads what content =
  match Otoml.Parser.from_string_result content with
  | Ok _ -> ()
  | Error message -> Alcotest.failf "%s: the result does not load: %s" what message

let ids content = Toml_line_editor.table_array_entry_ids content ~path:endpoints ~id_key:"id"

let sub_table_fixture =
  {|[[voice.stt.endpoints]]
id = "whisper-local"
kind = "openai_compat"

[voice.stt.endpoints.headers]
X-Trace = "on"

[[voice.stt.endpoints]]
id = "elevenlabs-stt"
|}

(* A table named under an entry's path belongs to that entry. Left behind, it
   becomes the first thing after the removal and the loader gives up on the
   whole file. *)
let test_removing_an_entry_takes_its_sub_table () =
  let out =
    Toml_line_editor.remove_table_array_entry sub_table_fixture ~path:endpoints ~id_key:"id"
      ~id:"whisper-local"
  in
  check_loads "removing an entry that owns a sub-table" out;
  Alcotest.(check bool) "the sub-table went with the entry that owned it" false
    (has_line out "[voice.stt.endpoints.headers]");
  Alcotest.(check (list string)) "the sibling entry survives" [ "elevenlabs-stt" ] (ids out)

(* This one loads cleanly either way, which is what makes it dangerous: slotted
   above the sub-table, the new entry owns headers that were written for its
   predecessor, and nothing reports it. *)
let test_a_new_entry_does_not_adopt_the_previous_sub_table () =
  let out =
    upsert sub_table_fixture ~path:endpoints ~id_key:"id" ~id:"added"
      ~fields:[ "kind", Some (Toml_line_editor.String "openai_compat") ]
  in
  check_loads "appending beside an entry that owns a sub-table" out;
  Alcotest.(check bool) "the sub-table stays under the entry it belongs to" true
    (index_of out "[voice.stt.endpoints.headers]" < index_of out {|id = "elevenlabs-stt"|});
  Alcotest.(check bool) "and the new entry lands after every existing one" true
    (index_of out {|id = "elevenlabs-stt"|} < index_of out {|id = "added"|})

let multiline_fixture =
  {|[[voice.stt.endpoints]]
id = "whisper-local"
notes = """
tuned against
[voice.stt.fallback]
enabled = true
"""
enabled = true
|}

(* An assignment inside a multi-line string is text, not a field. Writing there
   produces a file that parses, so nothing reports it, and the loader keeps
   reading the real field: the setting reads as saved and does not take. *)
let test_an_assignment_inside_a_multiline_string_is_not_a_field () =
  let out =
    upsert multiline_fixture ~path:endpoints ~id_key:"id" ~id:"whisper-local"
      ~fields:[ "enabled", Some (Toml_line_editor.Bool false) ]
  in
  check_loads "editing a field beside a multi-line string" out;
  Alcotest.(check int) "the line inside the string is left alone" 1
    (count_line out "enabled = true");
  Alcotest.(check int) "the real field is rewritten, once" 1 (count_line out "enabled = false")

let test_removing_beside_a_multiline_string_leaves_it_closed () =
  let trailing = "\n[[voice.stt.endpoints]]\nid = \"other\"\n" in
  let out =
    Toml_line_editor.remove_table_array_entry (multiline_fixture ^ trailing) ~path:endpoints
      ~id_key:"id" ~id:"other"
  in
  check_loads "removing an entry that follows a multi-line string" out;
  Alcotest.(check (list string)) "the entry carrying the string survives"
    [ "whisper-local" ] (ids out)

(* A value that runs past its own line has to be replaced whole. Overwriting
   only the opening line leaves the rest of the old array as loose text. *)
let test_replacing_a_multiline_array_field_closes_it () =
  let source =
    {|[[voice.stt.endpoints]]
id = "whisper-local"
models = [
  "one",
  "two",
]
enabled = true
|}
  in
  let out =
    upsert source ~path:endpoints ~id_key:"id" ~id:"whisper-local"
      ~fields:[ "models", Some (Toml_line_editor.String "solo") ]
  in
  check_loads "replacing a multi-line array with a scalar" out;
  Alcotest.(check bool) "the old elements are gone" false (has_line out {|  "one",|});
  Alcotest.(check bool) "the field that followed the array survives" true
    (has_line out "enabled = true")

let test_dropping_a_multiline_array_field_closes_it () =
  let source =
    {|[[voice.stt.endpoints]]
id = "whisper-local"
models = [
  "one",
]
enabled = true
|}
  in
  let out =
    upsert source ~path:endpoints ~id_key:"id" ~id:"whisper-local" ~fields:[ "models", None ]
  in
  check_loads "dropping a multi-line array field" out;
  Alcotest.(check bool) "no element is left behind" false (has_line out {|  "one",|})

(* An empty endpoint list is spelled as a key today, and an array-of-tables
   beside a key of the same path is a file the loader refuses outright. A line
   editor cannot merge the two shapes, so it says so rather than writing it. *)
let test_an_inline_key_at_the_path_is_refused () =
  match
    Toml_line_editor.upsert_table_array_entry "[voice.session]\nendpoints = []\n"
      ~path:"voice.session.endpoints" ~id_key:"id" ~id:"loopback"
      ~fields:[ "kind", Some (Toml_line_editor.String "voice_mcp") ]
  with
  | Error (Toml_line_editor.Inline_key_at_path path) ->
    Alcotest.(check string) "the refusal names the path" "voice.session.endpoints" path
  | Error other ->
    Alcotest.failf "wrong refusal: %s" (Toml_line_editor.entry_error_message other)
  | Ok produced -> Alcotest.failf "must be refused, but produced:\n%s" produced

let test_a_standard_table_at_the_path_is_refused () =
  match
    Toml_line_editor.upsert_table_array_entry "[voice.tts.endpoints]\nid = \"only-one\"\n"
      ~path:"voice.tts.endpoints" ~id_key:"id" ~id:"another" ~fields:[]
  with
  | Error (Toml_line_editor.Standard_table_at_path _) -> ()
  | Error other ->
    Alcotest.failf "wrong refusal: %s" (Toml_line_editor.entry_error_message other)
  | Ok produced -> Alcotest.failf "must be refused, but produced:\n%s" produced

(* On a CRLF file every line carries a trailing carriage return, and a header
   test that does not account for it answers no to every header. The editor then
   sees no entries at all and appends a duplicate of one already there. *)
let test_a_crlf_file_still_finds_its_entries () =
  let eol = Printf.sprintf "%c\n" (Char.chr 13) in
  let source =
    String.concat eol [ "[[voice.stt.endpoints]]"; {|id = "whisper-local"|}; "port = 1"; "" ]
  in
  Alcotest.(check (list string)) "the entry is found" [ "whisper-local" ] (ids source);
  let out =
    upsert source ~path:endpoints ~id_key:"id" ~id:"whisper-local"
      ~fields:[ "port", Some (Toml_line_editor.Int 2) ]
  in
  Alcotest.(check (list string)) "it was updated, not duplicated" [ "whisper-local" ] (ids out)

(* TOML refuses a raw control character inside a basic string, so a value that
   carries one has to be escaped or it kills the line it lands on. The check is
   a round trip rather than a spelling: what matters is that the loader reads
   back the value that was written. *)
let test_a_control_character_is_escaped () =
  let value = Printf.sprintf "a%cb" (Char.chr 7) in
  let line = Toml_line_editor.value_line ~key:"n" ~value:(Toml_line_editor.String value) in
  check_loads "a control character in a value" line;
  Alcotest.(check bool) "no raw control byte is emitted" false
    (String.exists (fun character -> Char.code character < 0x20) line);
  match Otoml.Parser.from_string_result line with
  | Error message -> Alcotest.fail message
  | Ok toml ->
    (match Otoml.find_opt toml Otoml.get_string [ "n" ] with
     | Some read -> Alcotest.(check string) "the value reads back as written" value read
     | None -> Alcotest.fail "the key did not survive the round trip")

(* A comment directly above a header describes that header. An entry appended
   below it inherits a description written for something else, and removing that
   entry would carry the description away. *)
let test_a_new_entry_lands_above_a_comment_documenting_the_next_table () =
  let note = "# documents the section below, not the entry above it" in
  let source =
    String.concat "\n"
      [ "[[voice.stt.endpoints]]"; {|id = "whisper-local"|}; ""; note; "[voice.session]"
      ; "endpoints = []"; "" ]
  in
  let out = upsert source ~path:endpoints ~id_key:"id" ~id:"added" ~fields:[] in
  check_loads "appending before a comment that documents the next table" out;
  Alcotest.(check bool) "the new entry sits above the comment" true
    (index_of out {|id = "added"|} < index_of out note);
  let back =
    Toml_line_editor.remove_table_array_entry out ~path:endpoints ~id_key:"id" ~id:"added"
  in
  Alcotest.(check string) "and removing it restores the file" source back

(* Two entries claiming one id is already a broken configuration, and this
   editor cannot choose between them. Applying to every match keeps the call
   meaning what it says -- the entry named by this id -- rather than picking one
   silently and leaving the other to be found later. *)
let test_a_duplicated_id_addresses_every_match () =
  let source =
    String.concat "\n"
      [ "[[voice.stt.endpoints]]"; {|id = "whisper-local"|}; "port = 1"; ""
      ; "[[voice.stt.endpoints]]"; {|id = "whisper-local"|}; "port = 2"; "" ]
  in
  let out =
    upsert source ~path:endpoints ~id_key:"id" ~id:"whisper-local"
      ~fields:[ "port", Some (Toml_line_editor.Int 9) ]
  in
  check_loads "editing a duplicated id" out;
  Alcotest.(check int) "every entry carrying the id took the field" 2 (count_line out "port = 9");
  let removed =
    Toml_line_editor.remove_table_array_entry source ~path:endpoints ~id_key:"id"
      ~id:"whisper-local"
  in
  Alcotest.(check (list string)) "and every one of them is removed" [] (ids removed)


(* A key with a dot in it is not one key with dots: TOML reads it as a path
   into nested tables. Written bare, [edgar.a.poe = "Yuna"] under
   [voice.tts.agent_voices] makes tables named edgar, a and poe, so the mapping
   written is not the mapping meant -- and a reader that asks for the agent
   named "edgar.a.poe" does not find it.

   [key_of_line] has always understood a quoted key. Only the writing side
   never produced one, which is why such a key could not round-trip. *)
let test_a_key_that_is_not_bare_is_quoted () =
  let out =
    Toml_line_editor.edit_table_scalar fixture ~path:"fusion.presets.trio"
      ~key:"edgar.a.poe" ~value:(Some "Yuna")
  in
  Alcotest.(check bool) "the key is written quoted" true
    (has_line out {|"edgar.a.poe" = "Yuna"|});
  Alcotest.(check bool) "and not as a path into tables" false
    (has_line out {|edgar.a.poe = "Yuna"|})

(* And it comes back as the one key it was. Written bare, the second edit
   appended a duplicate instead of replacing the first. *)
let test_a_quoted_key_is_found_again () =
  let once =
    Toml_line_editor.edit_table_scalar fixture ~path:"fusion.presets.trio"
      ~key:"edgar.a.poe" ~value:(Some "Yuna")
  in
  let twice =
    Toml_line_editor.edit_table_scalar once ~path:"fusion.presets.trio"
      ~key:"edgar.a.poe" ~value:(Some "Jamie")
  in
  Alcotest.(check bool) "the second edit replaced the first" true
    (has_line twice {|"edgar.a.poe" = "Jamie"|});
  Alcotest.(check bool) "and left no duplicate behind" false
    (has_line twice {|"edgar.a.poe" = "Yuna"|})

(* A bare key stays bare. Quoting every key would rewrite files an operator
   reads, for nothing. *)
let test_a_bare_key_is_left_alone () =
  let out =
    Toml_line_editor.edit_table_scalar fixture ~path:"fusion.presets.trio"
      ~key:"judge" ~value:(Some "new-judge")
  in
  Alcotest.(check bool) "no quotes were added" true
    (has_line out {|judge = "new-judge"|})

(* A key may carry an equals sign -- the writer quotes it for exactly that
   reason -- and the reader looked for the first [=] on the line, which cut
   such a key in half. The first save worked; the entry could never be found
   again, so a removal returned the text unchanged and said it succeeded. *)
let test_a_key_with_an_equals_sign_round_trips () =
  let key = "a=b" in
  let once =
    Toml_line_editor.edit_table_scalar fixture ~path:"fusion.presets.trio" ~key
      ~value:(Some "first")
  in
  Alcotest.(check bool) "the key is written quoted" true
    (has_line once {|"a=b" = "first"|});
  let twice =
    Toml_line_editor.edit_table_scalar once ~path:"fusion.presets.trio" ~key
      ~value:(Some "second")
  in
  Alcotest.(check bool) "the second edit replaced the first" true
    (has_line twice {|"a=b" = "second"|});
  Alcotest.(check bool) "and left no duplicate" false
    (has_line twice {|"a=b" = "first"|});
  let removed =
    Toml_line_editor.edit_table_scalar twice ~path:"fusion.presets.trio" ~key
      ~value:None
  in
  Alcotest.(check bool) "and removing it removes it" false
    (has_line removed {|"a=b" = "second"|})

(* A literal key is quoted the same way by the reader, so an equals sign in
   one is not an assignment either. *)
let test_a_literal_key_with_an_equals_sign_is_not_an_assignment () =
  Alcotest.(check (option string)) "the whole key, not its first half"
    (Some "x=y")
    (Toml_line_editor.key_of_line "'x=y' = \"value\"")

(* A quote inside the key is escaped like any other string content, so the
   line it lands on still parses. *)
let test_a_key_with_a_quote_is_escaped () =
  let out =
    Toml_line_editor.edit_table_scalar fixture ~path:"fusion.presets.trio"
      ~key:"say \"hi\"" ~value:(Some "Yuna")
  in
  Alcotest.(check bool) "the inner quotes are escaped" true
    (has_line out {|"say \"hi\"" = "Yuna"|})

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
        ; Alcotest.test_case "a None field is dropped from the entry" `Quick
            test_a_none_field_is_dropped_from_the_entry
        ; Alcotest.test_case "a new entry skips its None fields" `Quick
            test_a_new_entry_skips_its_none_fields
        ; Alcotest.test_case "dropping an absent field changes nothing" `Quick
            test_dropping_a_field_the_entry_lacks_changes_nothing
        ] )
    ; ( "what a line editor must not get wrong"
      , [ Alcotest.test_case "removing an entry takes its sub-table" `Quick
            test_removing_an_entry_takes_its_sub_table
        ; Alcotest.test_case "a new entry does not adopt the previous sub-table" `Quick
            test_a_new_entry_does_not_adopt_the_previous_sub_table
        ; Alcotest.test_case "an assignment inside a multi-line string is not a field" `Quick
            test_an_assignment_inside_a_multiline_string_is_not_a_field
        ; Alcotest.test_case "removing beside a multi-line string leaves it closed" `Quick
            test_removing_beside_a_multiline_string_leaves_it_closed
        ; Alcotest.test_case "replacing a multi-line array field closes it" `Quick
            test_replacing_a_multiline_array_field_closes_it
        ; Alcotest.test_case "dropping a multi-line array field closes it" `Quick
            test_dropping_a_multiline_array_field_closes_it
        ; Alcotest.test_case "an inline key at the path is refused" `Quick
            test_an_inline_key_at_the_path_is_refused
        ; Alcotest.test_case "a standard table at the path is refused" `Quick
            test_a_standard_table_at_the_path_is_refused
        ; Alcotest.test_case "a CRLF file still finds its entries" `Quick
            test_a_crlf_file_still_finds_its_entries
        ; Alcotest.test_case "a control character is escaped" `Quick
            test_a_control_character_is_escaped
        ; Alcotest.test_case "a new entry lands above a comment for the next table" `Quick
            test_a_new_entry_lands_above_a_comment_documenting_the_next_table
        ; Alcotest.test_case "a duplicated id addresses every match" `Quick
            test_a_duplicated_id_addresses_every_match
        ] )
    ; ( "keys the writer has to quote"
      , [ Alcotest.test_case "a key that is not bare is quoted" `Quick
            test_a_key_that_is_not_bare_is_quoted
        ; Alcotest.test_case "a quoted key is found again" `Quick
            test_a_quoted_key_is_found_again
        ; Alcotest.test_case "a bare key is left alone" `Quick
            test_a_bare_key_is_left_alone
        ; Alcotest.test_case "a key with a quote is escaped" `Quick
            test_a_key_with_a_quote_is_escaped
        ; Alcotest.test_case "a key with an equals sign round-trips" `Quick
            test_a_key_with_an_equals_sign_round_trips
        ; Alcotest.test_case "a literal key with an equals sign" `Quick
            test_a_literal_key_with_an_equals_sign_is_not_an_assignment
        ] )
    ]
