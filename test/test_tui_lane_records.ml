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
  (match Records.add quiz_toml bad_path with
   | Ok _ -> fail "expected an escaping path to be refused"
   | Error _ -> ());
  let wrong_kind_field = json {|{"source_id":"wiki","kind":"wiki","repository_id":"repo"}|} in
  match Records.add quiz_toml wrong_kind_field with
  | Ok _ -> fail "a reviewed field for another kind must not be silently discarded"
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
       | Ok (Updated _ | Apply _) | Error _ -> fail "expected Esc to cancel");
      (match Records.handle ~key:"d" overlay with
       | Ok (Records.Apply (_, text)) ->
           check bool "wkbl dropped" false (Option.is_some (index_of text "source_id = \"wkbl\""))
       | Ok (Updated _ | Cancel) | Error _ -> fail "expected d to apply a removal")

let expect_error label = function
  | Error _ -> ()
  | Ok _ -> fail label

let unsupported_shapes_are_not_empty () =
  let inline =
    "binding = { sources = [], records = [{ source_id = \"wiki\", kind = \"wiki\" }] }\n" in
  let array = "[binding]\nsources = []\nrecords = [{ source_id = \"wiki\", kind = \"wiki\" }]\n" in
  let empty_array = "[binding]\nsources = []\nrecords = []\n" in
  List.iter (fun text -> expect_error "unsupported shape must not look empty" (Records.open_ ~title:"x" ~text))
    [inline; array; empty_array]

let multiline_and_ambiguous_ids_fail_closed () =
  let entry = json {|{"source_id":"wkbl","kind":"wiki"}|} in
  let text = "[binding]\n[[binding.records]]\nsource_id = \"\"\"wk\\\n  bl\"\"\"\nkind = \"wiki\"" in
  List.iter (fun text ->
    (match Records.parse text with
     | Ok [record] -> check string "parsed multiline id" "wkbl" record.source_id
     | Ok _ | Error _ -> fail "multiline source id did not parse");
    expect_error "duplicate multiline id must be refused" (Records.add text entry);
    expect_error "unaddressable multiline id must not report deletion" (Records.remove text ~source_id:"wkbl");
    let overlay = match Records.open_ ~title:"x" ~text with Ok value -> value | Error e -> fail e in
    (match Records.handle ~key:"d" overlay with
     | Ok (Records.Updated overlay) -> check string "original draft preserved" text (Records.text overlay)
     | Ok (Apply _ | Cancel) | Error _ -> fail "unaddressable deletion applied"))
    [text; text ^ "\n"];
  let duplicate = "[binding]\n[[binding.records]]\nsource_id = \"wkbl\"\nkind = \"wiki\"\n[[binding.records]]\nsource_id = \"wkbl\"\nkind = \"wiki\"\n" in
  expect_error "ambiguous deletion must be refused" (Records.remove duplicate ~source_id:"wkbl");
  expect_error "duplicate must be refused" (Records.add duplicate entry);
  expect_error "an unrelated addition must not preserve an ambiguous set"
    (Records.add duplicate (json {|{"source_id":"new","kind":"wiki"}|}));
  let duplicate_with_other = duplicate ^ "[[binding.records]]\nsource_id = \"other\"\nkind = \"wiki\"\n" in
  expect_error "an unrelated deletion must not preserve an ambiguous set"
    (Records.remove duplicate_with_other ~source_id:"other");
  expect_error "missing id without trailing newline must not count a newline as deletion"
    (Records.remove "[binding]" ~source_id:"missing")

let preserves_subtables_and_header_comments () =
  let text = "[binding]\nsources = []\n[[binding.records]]\nsource_id = \"old\"\nkind = \"wiki\"\n[binding.records.extra]\nfoo = 42\n\n# schedule description\n[schedule]\nperiod = 5\n" in
  match Records.add text (json {|{"source_id":"new","kind":"wiki"}|}) with
  | Error detail -> fail detail
  | Ok result ->
      check_contains result "[binding.records.extra]\nfoo = 42\n";
      check_contains result "# schedule description\n[schedule]\n";
      (match index_of result "[binding.records.extra]", index_of result "source_id = \"new\"" with
       | Some extra, Some new_entry -> check bool "old subtable stays before new entry" true (extra < new_entry)
       | Some _, None | None, Some _ | None, None -> fail "expected both entries")

let overlay_form_and_large_list () =
  let text = "[binding]\n" ^ String.concat "" (List.init 30 (fun i ->
    Printf.sprintf "[[binding.records]]\nsource_id = \"id%d\"\nkind = \"wiki\"\n" i)) in
  let overlay = match Records.open_ ~title:"x" ~text with Ok value -> value | Error e -> fail e in
  let move overlay = match Records.handle ~key:"j" overlay with
    | Ok (Records.Updated next) -> next
    | Ok (Apply _ | Cancel) | Error _ -> fail "selection failed" in
  let overlay = List.fold_left (fun overlay _ -> move overlay) overlay (List.init 29 Fun.id) in
  check_contains (String.concat "\n" (Records.lines overlay)) "30/30 · id29";
  let overlay = match Records.handle ~key:"a" overlay with
    | Ok (Records.Updated next) -> next
    | Ok (Apply _ | Cancel) | Error _ -> fail "form did not open" in
  check bool "schema form open" true (Records.text_entry_open overlay);
  let rows = String.concat "\n" (Records.lines overlay) in
  check_contains rows "host requires an operator-owned declaration";
  check_contains rows "Before granting internal or direct";
  check_contains rows "source_id";
  check bool "list does not bury the form" false (Option.is_some (index_of rows "id29"));
  check_contains rows "Esc:back · then s saves"

let overlay_add_form_applies_to_draft () =
  let step key overlay = match Records.handle ~key overlay with
    | Ok (Records.Updated next) -> next
    | Ok (Apply _ | Cancel) | Error _ -> fail ("unexpected event on " ^ key) in
  let overlay = match Records.open_ ~title:"x" ~text:"[binding]\nsources = []\n" with
    | Ok value -> value | Error e -> fail e in
  let overlay = step "a" overlay |> Records.insert_text ~text:"fresh" |> step "tab"
    |> step "right" |> step "right" |> step "right" |> step "\019" in
  match Records.handle ~key:"enter" overlay with
  | Ok (Records.Apply (_, text)) ->
      (match Records.parse text with
       | Ok [record] ->
           check string "added source" "fresh" record.source_id;
           check string "added kind" "wiki" record.kind
       | Ok _ | Error _ -> fail "submitted grant did not parse")
  | Ok (Updated _ | Cancel) | Error _ -> fail "expected a staged edit"

let overlay_string_array_guidance_and_input () =
  let step key overlay = match Records.handle ~key overlay with
    | Ok (Records.Updated next) -> next
    | Ok (Apply _ | Cancel) -> fail ("unexpected event on " ^ key)
    | Error detail -> fail (key ^ ": " ^ detail) in
  let open_form () =
    match Records.open_ ~title:"x" ~text:"[binding]\nsources = []\n" with
    | Error detail -> fail detail
    | Ok overlay -> step "a" overlay in
  let visible overlay = String.concat "\n" (Records.lines overlay) in
  let type_text text overlay =
    String.fold_left (fun overlay char -> step (String.make 1 char) overlay) overlay text in
  let no_object_array_hint overlay =
    check bool "primitive array does not advertise Ctrl-E" false
      (Option.is_some (index_of (visible overlay) "Ctrl-E:array items")) in
  let submit overlay =
    match Records.handle ~key:"enter" (step "\019" overlay) with
    | Ok (Records.Apply (_, text)) -> (match Records.parse text with
        | Ok [record] -> record
        | Ok _ | Error _ -> fail "submitted grant did not parse")
    | Ok (Updated _ | Cancel) | Error _ -> fail "expected a staged edit" in
  let board = open_form () in
  check_contains (visible board) "Unique name, e.g. wkbl";
  let quoted_source = board |> Records.insert_text ~text:{|news"desk|} in
  check_contains (visible quoted_source) {|> source_id *: "news\"desk"|};
  let board = board |> Records.insert_text ~text:"news" |> step "tab" in
  check_contains (visible board) "What the installation may read";
  let board = board |> step "right" |> step "tab" in
  check_contains (visible board) {|["public", "internal"]|};
  check_contains (visible board) "Allowed: public, unlisted, internal, direct";
  no_object_array_hint board;
  let incomplete = board |> type_text {|["public"|} in
  check_contains (visible incomplete) {|> visibilities: "[\"public\""|};
  check bool "incomplete JSON is still refused" true
    (Result.is_error (Records.handle ~key:"tab" incomplete));
  let invalid = board |> type_text "[oops]" in
  check_contains (visible invalid) {|> visibilities: "[oops]"|};
  check bool "invalid JSON is still refused" true
    (Result.is_error (Records.handle ~key:"tab" invalid));
  let board = board |> type_text {|["public", "internal"]|} in
  check_contains (visible board) {|> visibilities: ["public","internal"]|};
  let board = submit board in
  check (list string) "board example is accepted" ["public"; "internal"] board.visibilities;
  let repository = open_form () |> Records.insert_text ~text:"code" |> step "tab"
    |> step "right" |> step "right" |> step "tab" |> step "tab" in
  check_contains (visible repository) "registered repository id";
  let repository = repository |> Records.insert_text ~text:"repo" |> step "tab" in
  check_contains (visible repository) {|["src/", "README.md"]|};
  no_object_array_hint repository;
  let repository = repository |> Records.insert_text ~text:{|["src/", "README.md"]|} |> submit in
  check (list string) "repository example is accepted" ["src/"; "README.md"] repository.paths

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
          test_case "unsupported TOML shapes" `Quick unsupported_shapes_are_not_empty;
          test_case "multiline and ambiguous ids" `Quick multiline_and_ambiguous_ids_fail_closed;
          test_case "subtables and header comments" `Quick preserves_subtables_and_header_comments;
          test_case "form and large list" `Quick overlay_form_and_large_list;
          test_case "add through form" `Quick overlay_add_form_applies_to_draft;
          test_case "string array guidance and input" `Quick overlay_string_array_guidance_and_input;
        ] );
    ]
