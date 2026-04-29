(* Tier W3 — Multimodal_keeper_bridge tests. *)

module B = Multimodal.Multimodal_keeper_bridge
module A = Multimodal.Artifact
module W = Multimodal.Workspace
module Aid = Shared_types.Artifact_id

let check_bool label b =
  if not b then failwith (Printf.sprintf "%s: false" label)

let check_int label expected actual =
  if expected <> actual then
    failwith
      (Printf.sprintf "%s: expected %d, got %d" label expected actual)

(* ── parse_kind_hint ────────────────────────────────────────── *)

let test_parse_known_hints () =
  check_bool "code" (B.parse_kind_hint "code" = Some A.Tag_code);
  check_bool "image" (B.parse_kind_hint "image" = Some A.Tag_image);
  check_bool "audio" (B.parse_kind_hint "audio" = Some A.Tag_audio);
  check_bool "doc" (B.parse_kind_hint "doc" = Some A.Tag_doc)

let test_parse_unknown_hint () =
  check_bool "unknown" (B.parse_kind_hint "video" = None);
  check_bool "empty" (B.parse_kind_hint "" = None);
  check_bool "uppercase" (B.parse_kind_hint "Code" = None)

(* ── hydrate_one ────────────────────────────────────────────── *)

let make_raw kind_hint =
  let valid_id = Aid.to_string (Aid.generate ()) in
  {
    B.id = valid_id;
    kind_hint;
    payload_json = `Assoc [ ("body", `String "x") ];
    metadata = `Assoc [ ("source", `String "test") ];
  }

let test_hydrate_one_known () =
  let raw = make_raw "code" in
  match
    B.hydrate_one raw ~now:1.0 ~created_by:"test"
      ~origin_artifact_ids:[]
  with
  | None -> failwith "expected Some artifact"
  | Some (A.Any art) ->
      check_bool "kind = Tag_code"
        (A.kind_to_tag art.kind = A.Tag_code)

let test_hydrate_one_unknown () =
  let raw = make_raw "video" in
  check_bool "unknown → None"
    (B.hydrate_one raw ~now:1.0 ~created_by:"test"
       ~origin_artifact_ids:[]
    = None)

let test_hydrate_one_malformed_id () =
  let raw =
    { (make_raw "image") with id = "not-a-uuid" }
  in
  match
    B.hydrate_one raw ~now:1.0 ~created_by:"test"
      ~origin_artifact_ids:[]
  with
  | None -> failwith "malformed id should still hydrate"
  | Some (A.Any art) ->
      (* metadata should record original id *)
      let md_str = Yojson.Safe.to_string art.metadata in
      check_bool "metadata records original id"
        (String.length md_str > 0
        &&
        let exists =
          try
            let _ = Str.search_forward
              (Str.regexp_string "original_external_id") md_str 0
            in
            true
          with Not_found -> false
        in
        exists)

let test_hydrate_one_provenance () =
  let parent = Aid.generate () in
  let raw = make_raw "image" in
  match
    B.hydrate_one raw ~now:5.0 ~created_by:"executor"
      ~origin_artifact_ids:[ parent ]
  with
  | None -> failwith "expected hydrate"
  | Some (A.Any art) ->
      check_bool "1 origin"
        (List.length art.provenance.origin_artifact_ids = 1);
      check_bool "created_by carries through"
        (String.equal art.provenance.created_by "executor");
      check_bool "created_at = 5.0"
        (Float.equal art.provenance.created_at 5.0)

(* ── hydrate_batch ──────────────────────────────────────────── *)

let test_hydrate_batch_skips_unknown () =
  let raws =
    [
      make_raw "code";
      make_raw "video"; (* skipped *)
      make_raw "image";
      make_raw "binary"; (* skipped *)
      make_raw "audio";
    ]
  in
  let arts = B.hydrate_batch raws ~now:1.0 ~created_by:"test" in
  check_int "3 known kinds → 3 artifacts" 3 (List.length arts)

let test_hydrate_batch_empty () =
  let arts = B.hydrate_batch [] ~now:1.0 ~created_by:"test" in
  check_int "empty → 0" 0 (List.length arts)

(* ── hydrate_with_workspace ─────────────────────────────────── *)

let test_hydrate_with_workspace () =
  let raws =
    [
      make_raw "code";
      make_raw "image";
      make_raw "video"; (* skipped *)
    ]
  in
  let ws, arts =
    B.hydrate_with_workspace W.empty raws ~now:1.0
      ~created_by:"test"
  in
  check_int "2 artifacts inserted" 2 (List.length arts);
  check_int "workspace size = 2" 2 (W.size ws)

let test_hydrate_preserves_existing_workspace () =
  let pre_aid = Aid.generate () in
  let pre_art : A.code A.t =
    {
      id = pre_aid;
      kind = A.Code;
      payload = Multimodal.Payload.Lazy_payload (fun () -> "x");
      metadata = `Null;
      provenance =
        {
          origin_artifact_ids = [];
          created_by = "pre";
          created_at = 0.0;
        };
    }
  in
  let ws0 = W.add W.empty (A.Any pre_art) in
  let ws, _ =
    B.hydrate_with_workspace ws0 [ make_raw "image" ] ~now:1.0
      ~created_by:"test"
  in
  check_int "size 2 (pre + new)" 2 (W.size ws)

(* ── Driver ─────────────────────────────────────────────────── *)

let () =
  let cases =
    [
      ("parse_known_hints", test_parse_known_hints);
      ("parse_unknown_hint", test_parse_unknown_hint);
      ("hydrate_one_known", test_hydrate_one_known);
      ("hydrate_one_unknown", test_hydrate_one_unknown);
      ("hydrate_one_malformed_id", test_hydrate_one_malformed_id);
      ("hydrate_one_provenance", test_hydrate_one_provenance);
      ("hydrate_batch_skips_unknown", test_hydrate_batch_skips_unknown);
      ("hydrate_batch_empty", test_hydrate_batch_empty);
      ("hydrate_with_workspace", test_hydrate_with_workspace);
      ( "hydrate_preserves_existing_workspace",
        test_hydrate_preserves_existing_workspace );
    ]
  in
  List.iter
    (fun (name, f) ->
      try f ()
      with e ->
        Printf.printf "FAIL %s: %s\n" name (Printexc.to_string e);
        exit 1)
    cases;
  Printf.printf "test_multimodal_keeper_bridge: %d cases OK\n"
    (List.length cases)
