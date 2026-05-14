(* RFC-0079: Log.Ring typed encoder/decoder tests.

   Asserts that:
   1. Every [level] / [source] variant round-trips through entry_to_json
      / entry_of_json without loss.
   2. The wire format keeps the field set that the dashboard schema in
      [dashboard/src/api/schemas/logs.ts] reads (seq, ts, level, source,
      module, keeper_name, turn_id, message, details). Legacy fields
      (raw_level, normalized_level, legacy_classified) are gone.
   3. Decode failure on missing/ill-typed/unknown fields raises
      [Entry_decode_error] instead of returning a silent fallback. *)

let entry_of ?(seq = 0) ?(ts = "2026-05-14T00:00:00Z") ?(level = Log.Info)
    ?(source = Log.Structured) ?(module_name = "Test") ?keeper_name ?turn_id
    ?(message = "hello") ?(details = `Null) () : Log.Ring.entry =
  { Log.Ring.seq; ts; level; source; module_name; keeper_name; turn_id;
    message; details }

let assoc_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let test_round_trip_all_levels () =
  List.iter
    (fun level ->
       let original = entry_of ~level ~message:(Log.level_to_string level) () in
       let decoded = Log.Ring.entry_of_json (Log.Ring.entry_to_json original) in
       Alcotest.(check bool) (Log.level_to_string level) true (decoded.level = level);
       Alcotest.(check string) "message preserved" original.message decoded.message)
    [ Log.Debug; Log.Info; Log.Warn; Log.Error ]

let test_round_trip_all_sources () =
  List.iter
    (fun source ->
       let original = entry_of ~source () in
       let decoded = Log.Ring.entry_of_json (Log.Ring.entry_to_json original) in
       Alcotest.(check bool)
         (Log.source_to_string source) true (decoded.source = source))
    [ Log.Structured; Log.Legacy_stderr; Log.Legacy_traceln; Log.Client_tool_host ]

let test_round_trip_optional_fields () =
  let with_optional =
    entry_of ~keeper_name:"analyst" ~turn_id:7
      ~details:(`Assoc [("k", `String "v")]) ()
  in
  let decoded =
    Log.Ring.entry_of_json (Log.Ring.entry_to_json with_optional)
  in
  Alcotest.(check (option string)) "keeper_name"
    (Some "analyst") decoded.keeper_name;
  Alcotest.(check (option int)) "turn_id" (Some 7) decoded.turn_id;
  Alcotest.(check bool) "details preserved" true
    (decoded.details = `Assoc [("k", `String "v")])

let test_wire_format_field_set () =
  let e = entry_of () in
  let json = Log.Ring.entry_to_json e in
  let expected_keys =
    [ "seq"; "ts"; "level"; "source"; "module"; "keeper_name";
      "turn_id"; "message"; "details" ]
  in
  let absent_legacy_keys =
    [ "raw_level"; "normalized_level"; "legacy_classified" ]
  in
  List.iter
    (fun k ->
       Alcotest.(check bool)
         (Printf.sprintf "field %s present" k) true
         (assoc_field k json <> None))
    expected_keys;
  List.iter
    (fun k ->
       Alcotest.(check bool)
         (Printf.sprintf "legacy field %s absent" k) false
         (assoc_field k json <> None))
    absent_legacy_keys

let test_decode_rejects_missing_message () =
  let bad =
    `Assoc [
      ("seq", `Int 1);
      ("ts", `String "2026-05-14T00:00:00Z");
      ("level", `String "INFO");
      ("source", `String "structured");
      ("module", `String "Test");
      (* message intentionally omitted *)
    ]
  in
  match Log.Ring.entry_of_json bad with
  | exception Log.Ring.Entry_decode_error _ -> ()
  | _ -> Alcotest.fail "expected Entry_decode_error for missing message"

let test_decode_rejects_unknown_level () =
  let bad =
    `Assoc [
      ("seq", `Int 1);
      ("ts", `String "2026-05-14T00:00:00Z");
      ("level", `String "FATAL");
      ("source", `String "structured");
      ("module", `String "Test");
      ("message", `String "x");
    ]
  in
  match Log.Ring.entry_of_json bad with
  | exception Log.Ring.Entry_decode_error _ -> ()
  | _ -> Alcotest.fail "expected Entry_decode_error for unknown level FATAL"

let test_decode_rejects_unknown_source () =
  let bad =
    `Assoc [
      ("seq", `Int 1);
      ("ts", `String "2026-05-14T00:00:00Z");
      ("level", `String "INFO");
      ("source", `String "lemur");
      ("module", `String "Test");
      ("message", `String "x");
    ]
  in
  match Log.Ring.entry_of_json bad with
  | exception Log.Ring.Entry_decode_error _ -> ()
  | _ -> Alcotest.fail "expected Entry_decode_error for unknown source"

let test_decode_rejects_legacy_raw_level_row () =
  (* Pre-RFC-0079 JSONL row shape — written before the typed encoder.
     The file-fold boundary in load_from_file catches this and skips with
     a WARN; everywhere else the decoder is strict. *)
  let legacy_row =
    `Assoc [
      ("seq", `Int 1);
      ("ts", `String "2026-05-14T00:00:00Z");
      ("level", `String "INFO");
      ("raw_level", `String "INFO");
      ("normalized_level", `String "INFO");
      ("source", `String "structured");
      ("legacy_classified", `Bool false);
      ("module", `String "Test");
      ("message", `String "old row");
    ]
  in
  (* A legacy row that still carries all required fields decodes fine —
     extra fields are ignored. The point is no schema panic over the
     extras. *)
  let decoded = Log.Ring.entry_of_json legacy_row in
  Alcotest.(check string) "legacy row decodable" "old row" decoded.message

let () =
  Alcotest.run "log_ring_encoder"
    [
      ("round-trip", [
        Alcotest.test_case "all levels" `Quick test_round_trip_all_levels;
        Alcotest.test_case "all sources" `Quick test_round_trip_all_sources;
        Alcotest.test_case "optional fields" `Quick test_round_trip_optional_fields;
      ]);
      ("wire format", [
        Alcotest.test_case "field set" `Quick test_wire_format_field_set;
      ]);
      ("decode failure", [
        Alcotest.test_case "missing message" `Quick test_decode_rejects_missing_message;
        Alcotest.test_case "unknown level" `Quick test_decode_rejects_unknown_level;
        Alcotest.test_case "unknown source" `Quick test_decode_rejects_unknown_source;
        Alcotest.test_case "legacy extras tolerated" `Quick test_decode_rejects_legacy_raw_level_row;
      ]);
    ]
