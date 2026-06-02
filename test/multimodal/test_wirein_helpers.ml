(* Tier K1 — Multimodal.Wirein_helpers unit tests. *)

module H = Multimodal.Wirein_helpers
module B = Multimodal.Multimodal_keeper_bridge

let test_disabled_by_default () =
  Unix.putenv "MASC_MULTIMODAL" "";
  assert (not (H.masc_multimodal_enabled ()));
  print_endline "  disabled_by_default: OK"

let test_enabled_with_flag () =
  Unix.putenv "MASC_MULTIMODAL" "1";
  assert (H.masc_multimodal_enabled ());
  Unix.putenv "MASC_MULTIMODAL" "true";
  assert (H.masc_multimodal_enabled ());
  Unix.putenv "MASC_MULTIMODAL" "yes";
  assert (H.masc_multimodal_enabled ());
  Unix.putenv "MASC_MULTIMODAL" "on";
  assert (H.masc_multimodal_enabled ());
  Unix.putenv "MASC_MULTIMODAL" "";
  print_endline "  enabled_with_flag: OK"

let test_extract_none () =
  let raws, wc = H.extract_raw_artifacts None in
  assert (raws = []);
  assert (wc = None);
  print_endline "  extract_none: OK"

let test_extract_no_key () =
  let wc = Some (`Assoc [ ("other_key", `String "value") ]) in
  let raws, wc' = H.extract_raw_artifacts wc in
  assert (raws = []);
  assert (wc = wc');
  print_endline "  extract_no_key: OK"

let test_extract_well_formed () =
  let wc =
    Some
      (`Assoc
        [
          ( "multimodal_artifacts",
            `List
              [
                `Assoc
                  [
                    ( "id",
                      `String "01900000-0000-7000-8000-000000000010" );
                    ("kind_hint", `String "code");
                    ("payload_json", `String "println");
                    ("metadata", `Null);
                  ];
                `Assoc
                  [
                    ( "id",
                      `String "01900000-0000-7000-8000-000000000011" );
                    ("kind_hint", `String "image");
                    ("payload_json", `Null);
                    ("metadata", `Null);
                  ];
              ] );
          ("other_key", `String "preserved");
        ])
  in
  let raws, wc' = H.extract_raw_artifacts wc in
  assert (List.length raws = 2);
  let first = List.nth raws 0 in
  assert (first.B.kind_hint = "code");
  (match wc' with
   | Some (`Assoc kv) ->
       assert (List.assoc_opt "multimodal_artifacts" kv = None);
       assert (List.assoc_opt "other_key" kv = Some (`String "preserved"))
   | _ -> assert false);
  print_endline "  extract_well_formed: OK"

let test_extract_skips_malformed () =
  let wc =
    Some
      (`Assoc
        [
          ( "multimodal_artifacts",
            `List
              [
                `Assoc
                  [
                    ("id", `String "01900000-0000-7000-8000-000000000020");
                    ("kind_hint", `String "doc");
                    ("payload_json", `Null);
                    ("metadata", `Null);
                  ];
                `Assoc [ ("kind_hint", `String "image") ]
                (* missing id *);
                `String "not an object";
              ] );
        ])
  in
  let raws, _ = H.extract_raw_artifacts wc in
  assert (List.length raws = 1);
  print_endline "  extract_skips_malformed: OK"

let test_upsert_workspace_meta_none () =
  let meta = `Assoc [ ("workspace_size", `Int 3) ] in
  let wc = H.upsert_workspace_meta None meta in
  (match wc with
   | Some (`Assoc kv) ->
       assert (List.assoc_opt "workspace_meta" kv = Some meta)
   | _ -> assert false);
  print_endline "  upsert_meta_none_input: OK"

let test_upsert_workspace_meta_replaces () =
  let prev =
    Some
      (`Assoc
        [
          ("workspace_meta", `Assoc [ ("workspace_size", `Int 0) ]);
          ("autonomous_meta", `Assoc [ ("phase", `String "idle") ]);
        ])
  in
  let new_meta = `Assoc [ ("workspace_size", `Int 5) ] in
  let wc = H.upsert_workspace_meta prev new_meta in
  (match wc with
   | Some (`Assoc kv) ->
       assert (List.assoc_opt "workspace_meta" kv = Some new_meta);
       assert (
         List.assoc_opt "autonomous_meta" kv
         = Some (`Assoc [ ("phase", `String "idle") ]))
   | _ -> assert false);
  print_endline "  upsert_meta_replaces_preserves_other_keys: OK"

let () =
  print_endline "=== Wirein_helpers ===";
  test_disabled_by_default ();
  test_enabled_with_flag ();
  test_extract_none ();
  test_extract_no_key ();
  test_extract_well_formed ();
  test_extract_skips_malformed ();
  test_upsert_workspace_meta_none ();
  test_upsert_workspace_meta_replaces ();
  print_endline "=== Wirein_helpers: 8/8 OK ==="
