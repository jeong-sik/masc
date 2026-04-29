(* Tier K2 — Multimodal.Keeper_emitter unit tests. *)

module E = Multimodal.Keeper_emitter
module A = Multimodal.Artifact

let yojson_eq a b = Yojson.Safe.equal a b

let assoc_lookup_list (wc : Yojson.Safe.t option) (key : string)
    : Yojson.Safe.t list =
  match wc with
  | Some (`Assoc kv) -> (
      match List.assoc_opt key kv with
      | Some (`List xs) -> xs
      | _ -> [])
  | _ -> []

let test_emit_into_none () =
  let wc =
    E.emit ~working_context:None
      ~id:"01900000-0000-7000-8000-000000000001"
      ~kind_tag:A.Tag_code
      ~payload_json:(`String "println")
      ~metadata:`Null
  in
  let entries = assoc_lookup_list wc "multimodal_artifacts" in
  assert (List.length entries = 1);
  (match List.hd entries with
   | `Assoc kv ->
       assert (List.assoc_opt "kind_hint" kv = Some (`String "code"));
       assert (
         List.assoc_opt "id" kv
         = Some
             (`String "01900000-0000-7000-8000-000000000001"))
   | _ -> assert false);
  print_endline "  emit_into_none: OK"

let test_emit_preserves_other_keys () =
  let initial =
    Some
      (`Assoc
        [
          ("autonomous_meta", `Assoc [ ("phase", `String "executing") ]);
          ("custom", `Int 42);
        ])
  in
  let wc =
    E.emit ~working_context:initial
      ~id:"01900000-0000-7000-8000-000000000010"
      ~kind_tag:A.Tag_image
      ~payload_json:(`String "<base64>")
      ~metadata:(`Assoc [ ("width", `Int 512) ])
  in
  (match wc with
   | Some (`Assoc kv) ->
       assert (
         List.assoc_opt "autonomous_meta" kv
         = Some
             (`Assoc [ ("phase", `String "executing") ]));
       assert (List.assoc_opt "custom" kv = Some (`Int 42));
       let entries = assoc_lookup_list wc "multimodal_artifacts" in
       assert (List.length entries = 1)
   | _ -> assert false);
  print_endline "  emit_preserves_other_keys: OK"

let test_emit_appends_to_existing_list () =
  let wc1 =
    E.emit ~working_context:None
      ~id:"01900000-0000-7000-8000-000000000020"
      ~kind_tag:A.Tag_code
      ~payload_json:(`String "first")
      ~metadata:`Null
  in
  let wc2 =
    E.emit ~working_context:wc1
      ~id:"01900000-0000-7000-8000-000000000021"
      ~kind_tag:A.Tag_doc
      ~payload_json:(`String "second")
      ~metadata:`Null
  in
  let entries = assoc_lookup_list wc2 "multimodal_artifacts" in
  assert (List.length entries = 2);
  (* Order preserved: first then second. *)
  (match entries with
   | [ first; second ] ->
       assert (
         yojson_eq
           (Yojson.Safe.Util.member "payload_json" first)
           (`String "first"));
       assert (
         yojson_eq
           (Yojson.Safe.Util.member "payload_json" second)
           (`String "second"))
   | _ -> assert false);
  print_endline "  emit_appends_in_order: OK"

let test_kind_hint_strings () =
  let cases =
    [
      (A.Tag_code, "code");
      (A.Tag_image, "image");
      (A.Tag_audio, "audio");
      (A.Tag_doc, "doc");
    ]
  in
  List.iter
    (fun (tag, expected) ->
      let wc =
        E.emit ~working_context:None
          ~id:"01900000-0000-7000-8000-000000000030"
          ~kind_tag:tag ~payload_json:`Null ~metadata:`Null
      in
      let entries = assoc_lookup_list wc "multimodal_artifacts" in
      let hint =
        match List.hd entries with
        | `Assoc kv -> List.assoc "kind_hint" kv
        | _ -> assert false
      in
      assert (yojson_eq hint (`String expected)))
    cases;
  print_endline "  kind_hint_canonical_strings: OK"

let test_emit_many () =
  let entries =
    [
      ( "01900000-0000-7000-8000-000000000040",
        A.Tag_code,
        `String "code",
        `Null );
      ( "01900000-0000-7000-8000-000000000041",
        A.Tag_image,
        `String "img",
        `Null );
      ( "01900000-0000-7000-8000-000000000042",
        A.Tag_audio,
        `String "wav",
        `Null );
    ]
  in
  let wc = E.emit_many ~working_context:None entries in
  let result = assoc_lookup_list wc "multimodal_artifacts" in
  assert (List.length result = 3);
  print_endline "  emit_many: OK"

let test_round_trip_to_keeper_bridge () =
  (* Producer (K2) → Consumer (K1) round-trip. *)
  let wc =
    E.emit ~working_context:None
      ~id:"01900000-0000-7000-8000-000000000050"
      ~kind_tag:A.Tag_image
      ~payload_json:(`Assoc [ ("url", `String "data:image/png") ])
      ~metadata:(`Assoc [ ("dim", `String "512x512") ])
  in
  let raws, _wc_rest =
    Multimodal.Wirein_helpers.extract_raw_artifacts wc
  in
  assert (List.length raws = 1);
  let raw = List.hd raws in
  assert (raw.Multimodal.Multimodal_keeper_bridge.id
          = "01900000-0000-7000-8000-000000000050");
  assert (raw.kind_hint = "image");
  print_endline "  emitter_to_wirein_round_trip: OK"

let () =
  print_endline "=== Keeper_emitter ===";
  test_emit_into_none ();
  test_emit_preserves_other_keys ();
  test_emit_appends_to_existing_list ();
  test_kind_hint_strings ();
  test_emit_many ();
  test_round_trip_to_keeper_bridge ();
  print_endline "=== Keeper_emitter: 6/6 OK ==="
