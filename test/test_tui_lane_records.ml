open Alcotest

module Records = Masc_tui_lane_records

let quiz_toml =
  "# operator quiz lane\n[binding]\nsources = [\"board\"]\n\n[[binding.records]]\nsource_id = \"wkbl\"\nkind = \"repository\"\nrepository_id = \"wkbl\"\npaths = [\"docs/\"]\n"

let json text = Yojson.Safe.from_string text

let index_of text needle =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec loop offset =
    if offset + needle_length > text_length then None
    else if String.sub text offset needle_length = needle then Some offset
    else loop (offset + 1) in
  loop 0

let check_contains text needle =
  check bool ("contains " ^ needle) true (Option.is_some (index_of text needle))

let parse_two_entries () =
  let text =
    quiz_toml ^ "\n[[binding.records]]\nsource_id = \"notes\"\nkind = \"board\"\nvisibilities = [\"public\", \"internal\"]\n" in
  match Records.parse text with
  | Error detail -> fail ("parse failed: " ^ detail)
  | Ok [wkbl; notes] ->
      check string "wkbl id" "wkbl" wkbl.source_id;
      check string "wkbl kind" "repository" wkbl.kind;
      check (option string) "wkbl repo" (Some "wkbl") wkbl.repository_id;
      check (list string) "wkbl paths" ["docs/"] wkbl.paths;
      check string "notes id" "notes" notes.source_id;
      check (list string) "notes vis" ["public"; "internal"] notes.visibilities
  | Ok records -> fail ("expected 2 records, got " ^ string_of_int (List.length records))

let parse_without_records_is_empty () =
  match Records.parse "[binding]\nsources = []\n" with
  | Ok [] -> ()
  | Ok records -> fail ("expected no records, got " ^ string_of_int (List.length records))
  | Error detail -> fail ("parse failed: " ^ detail)

let parse_malformed_entry_errors () =
  match Records.parse "[binding]\n[[binding.records]]\nkind = \"board\"\n" with
  | Ok _ -> fail "expected an error for a record without source_id"
  | Error _ -> ()

let add_board_round_trip () =
  let entry =
    json {|{"source_id":"notes","kind":"board","visibilities":["public","direct"]}|} in
  match Records.add quiz_toml entry with
  | Error detail -> fail ("add failed: " ^ detail)
  | Ok text ->
      check_contains text "# operator quiz lane";
      check_contains text "source_id = \"notes\"";
      check_contains text "visibilities = [\"public\", \"direct\"]";
      (match Records.parse text with
       | Error detail -> fail ("reparse failed: " ^ detail)
       | Ok records ->
           check int "two records" 2 (List.length records);
           check string "second id" "notes" (List.nth records 1).source_id)

let add_appends_after_last_entry () =
  let entry = json {|{"source_id":"notes","kind":"wiki"}|} in
  match Records.add quiz_toml entry with
  | Error detail -> fail ("add failed: " ^ detail)
  | Ok text -> (
      match index_of text "source_id = \"wkbl\"", index_of text "source_id = \"notes\"" with
      | Some first, Some second -> check bool "appended after" true (first < second)
      | _ -> fail "both entries must be present")

let add_duplicate_refused () =
  let entry = json {|{"source_id":"wkbl","kind":"wiki"}|} in
  match Records.add quiz_toml entry with
  | Ok _ -> fail "expected a duplicate source_id to be refused"
  | Error _ -> ()

let add_unknown_kind_refused () =
  let entry = json {|{"source_id":"x","kind":"artifact"}|} in
  match Records.add quiz_toml entry with
  | Ok _ -> fail "expected an unknown kind to be refused"
  | Error _ -> ()

let add_rejects_host_invalid_values () =
  let bad_visibility = json {|{"source_id":"x","kind":"board","visibilities":["everywhere"]}|} in
  let bad_path = json {|{"source_id":"y","kind":"repository","repository_id":"r","paths":["../escape"]}|} in
  (match Records.add quiz_toml bad_visibility with
   | Ok _ -> fail "expected an unknown visibility to be refused"
   | Error _ -> ());
  match Records.add quiz_toml bad_path with
  | Ok _ -> fail "expected an escaping path to be refused"
  | Error _ -> ()

let add_without_binding_refused () =
  let entry = json {|{"source_id":"x","kind":"wiki"}|} in
  match Records.add "[lane]\nname = \"x\"\n" entry with
  | Ok _ -> fail "expected a missing [binding] table to be refused"
  | Error _ -> ()

let remove_drops_one_entry () =
  let entry = json {|{"source_id":"notes","kind":"wiki"}|} in
  match Records.add quiz_toml entry with
  | Error detail -> fail ("add failed: " ^ detail)
  | Ok text -> (
      match Records.remove text ~source_id:"wkbl" with
      | Error detail -> fail ("remove failed: " ^ detail)
      | Ok next ->
          check bool "wkbl gone" false (Option.is_some (index_of next "source_id = \"wkbl\""));
          check_contains next "source_id = \"notes\"";
          check_contains next "# operator quiz lane")

let remove_missing_refused () =
  match Records.remove quiz_toml ~source_id:"nobody" with
  | Ok _ -> fail "expected removing a missing record to be refused"
  | Error _ -> ()

let overlay_cancel_and_drop () =
  match Records.open_ ~title:"operator-quiz.toml" ~text:quiz_toml with
  | Error detail -> fail ("open failed: " ^ detail)
  | Ok overlay ->
      check bool "lines render" true (Records.lines overlay <> []);
      (match Records.handle ~key:"esc" overlay with
       | Ok Records.Cancel -> ()
       | _ -> fail "expected Esc to cancel");
      (match Records.handle ~key:"d" overlay with
       | Ok (Records.Apply (_, text)) ->
           check bool "wkbl dropped" false (Option.is_some (index_of text "source_id = \"wkbl\""))
       | _ -> fail "expected d to apply a removal")

let () =
  run "tui lane records"
    [
      ( "records",
        [
          test_case "parse two entries" `Quick parse_two_entries;
          test_case "no records is empty" `Quick parse_without_records_is_empty;
          test_case "malformed entry errors" `Quick parse_malformed_entry_errors;
          test_case "add board round trip" `Quick add_board_round_trip;
          test_case "add appends after last" `Quick add_appends_after_last_entry;
          test_case "duplicate refused" `Quick add_duplicate_refused;
          test_case "unknown kind refused" `Quick add_unknown_kind_refused;
          test_case "host-invalid refused" `Quick add_rejects_host_invalid_values;
          test_case "missing binding refused" `Quick add_without_binding_refused;
          test_case "remove drops one" `Quick remove_drops_one_entry;
          test_case "remove missing refused" `Quick remove_missing_refused;
          test_case "overlay cancel and drop" `Quick overlay_cancel_and_drop;
        ] );
    ]
