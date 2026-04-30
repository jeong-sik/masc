(* Tier K3 — Multimodal.Tool_emission unit tests. *)

module T = Multimodal.Tool_emission
module A = Multimodal.Artifact

let test_extract_kind_present () =
  let result =
    `Assoc
      [
        (T.multimodal_kind_key, `String "image");
        ("other", `String "x");
      ]
  in
  assert (T.extract_kind_from_result result = Some A.Tag_image);
  print_endline "  extract_kind_present: OK"

let test_extract_kind_absent () =
  let result = `Assoc [ ("other", `String "x") ] in
  assert (T.extract_kind_from_result result = None);
  print_endline "  extract_kind_absent: OK"

let test_extract_kind_unknown_string () =
  let result =
    `Assoc [ (T.multimodal_kind_key, `String "video") ]
  in
  assert (T.extract_kind_from_result result = None);
  print_endline "  extract_kind_unknown_string: OK"

let test_extract_kind_non_string () =
  let result = `Assoc [ (T.multimodal_kind_key, `Int 1) ] in
  assert (T.extract_kind_from_result result = None);
  print_endline "  extract_kind_non_string: OK"

let test_extract_kind_non_assoc () =
  assert (T.extract_kind_from_result (`String "image") = None);
  assert (T.extract_kind_from_result `Null = None);
  print_endline "  extract_kind_non_assoc: OK"

let test_extract_id () =
  let result =
    `Assoc [ (T.multimodal_id_key, `String "01900000-0000-7000-8000-000000000001") ]
  in
  assert (
    T.extract_id_from_result result
    = Some "01900000-0000-7000-8000-000000000001");
  print_endline "  extract_id: OK"

let test_emit_no_tag_returns_unchanged () =
  let initial = Some (`Assoc [ ("preserve", `String "yes") ]) in
  let result =
    `Assoc
      [
        ("just_data", `String "regular tool output");
        ("count", `Int 42);
      ]
  in
  let wc = T.emit_from_tool_result ~working_context:initial ~result in
  assert (wc = initial);
  print_endline "  emit_no_tag_returns_unchanged: OK"

let test_emit_missing_id_returns_unchanged () =
  let initial = None in
  let result =
    `Assoc [ (T.multimodal_kind_key, `String "code") ]
  in
  let wc = T.emit_from_tool_result ~working_context:initial ~result in
  assert (wc = initial);
  print_endline "  emit_missing_id_returns_unchanged: OK"

let test_emit_strips_reserved_keys_from_payload () =
  let result =
    `Assoc
      [
        (T.multimodal_kind_key, `String "code");
        (T.multimodal_id_key, `String "01900000-0000-7000-8000-000000000010");
        (T.multimodal_metadata_key, `Assoc [ ("lang", `String "ml") ]);
        ("source", `String "let x = 1");
      ]
  in
  let wc =
    T.emit_from_tool_result ~working_context:None ~result
  in
  let raws, _ = Multimodal.Wirein_helpers.extract_raw_artifacts wc in
  assert (List.length raws = 1);
  let raw = List.hd raws in
  assert (raw.Multimodal.Multimodal_keeper_bridge.kind_hint = "code");
  (* payload_json should contain only "source", reserved keys stripped. *)
  (match raw.payload_json with
   | `Assoc kv ->
       assert (List.assoc_opt "source" kv = Some (`String "let x = 1"));
       assert (List.assoc_opt T.multimodal_kind_key kv = None);
       assert (List.assoc_opt T.multimodal_id_key kv = None);
       assert (List.assoc_opt T.multimodal_metadata_key kv = None)
   | _ -> assert false);
  (* metadata forwarded from __multimodal_metadata. *)
  (match raw.metadata with
   | `Assoc kv ->
       assert (List.assoc_opt "lang" kv = Some (`String "ml"))
   | _ -> assert false);
  print_endline "  emit_strips_reserved_keys: OK"

let test_emit_metadata_default_when_absent () =
  let result =
    `Assoc
      [
        (T.multimodal_kind_key, `String "doc");
        (T.multimodal_id_key, `String "01900000-0000-7000-8000-000000000020");
        ("body", `String "# Title");
      ]
  in
  let wc =
    T.emit_from_tool_result ~working_context:None ~result
  in
  let raws, _ = Multimodal.Wirein_helpers.extract_raw_artifacts wc in
  let raw = List.hd raws in
  assert (raw.metadata = `Assoc []);
  print_endline "  emit_metadata_defaults_to_empty_assoc: OK"

let test_emit_from_tool_results_bulk () =
  let r1 =
    `Assoc
      [
        (T.multimodal_kind_key, `String "code");
        (T.multimodal_id_key, `String "01900000-0000-7000-8000-000000000030");
      ]
  in
  let r2 =
    `Assoc
      [
        (T.multimodal_kind_key, `String "image");
        (T.multimodal_id_key, `String "01900000-0000-7000-8000-000000000031");
      ]
  in
  (* untagged result — should be ignored *)
  let r3 = `Assoc [ ("regular", `String "data") ] in
  let r4 =
    `Assoc
      [
        (T.multimodal_kind_key, `String "audio");
        (T.multimodal_id_key, `String "01900000-0000-7000-8000-000000000032");
      ]
  in
  let wc =
    T.emit_from_tool_results ~working_context:None [ r1; r2; r3; r4 ]
  in
  let raws, _ = Multimodal.Wirein_helpers.extract_raw_artifacts wc in
  assert (List.length raws = 3);
  print_endline "  emit_bulk_skips_untagged: OK"

let () =
  print_endline "=== Tool_emission ===";
  test_extract_kind_present ();
  test_extract_kind_absent ();
  test_extract_kind_unknown_string ();
  test_extract_kind_non_string ();
  test_extract_kind_non_assoc ();
  test_extract_id ();
  test_emit_no_tag_returns_unchanged ();
  test_emit_missing_id_returns_unchanged ();
  test_emit_strips_reserved_keys_from_payload ();
  test_emit_metadata_default_when_absent ();
  test_emit_from_tool_results_bulk ();
  print_endline "=== Tool_emission: 11/11 OK ==="
