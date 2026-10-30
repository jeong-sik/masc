module AR = Masc.Task.Anti_rationalization
module V = Masc.Verifier_review_original

let sample_image : AR.evidence_image =
  { image_reference = "artifact:repos/masc/evidence/shot.png"
  ; image_sha256 = "abc123"
  ; image_bytes = 42
  ; image_media_type = "image/png"
  ; image_body_base64 = "aGVsbG8="
  }

let sample_request : AR.review_request =
  { task_title = "Repair checkout discovery"
  ; task_description = "Keep .git symlink boundaries"
  ; completion_notes = "Merged and verified"
  ; agent_name = "jazz-developer"
  ; task_id = "task-2500"
  ; evidence_refs = [ "note:merge commit 07e85f32"; "note:runner 39902404391" ]
  ; evidence_images = [ sample_image ]
  }

let sample_question : AR.verdict_question =
  { completion_contract = Some [ "dune build @check passes" ]
  ; required_evidence = [ "minimal build green" ]
  ; evidence_posture = AR.Usable_artifacts 1
  ; few_shot_block = ""
  }

let sample_root : AR.lookup_root = AR.Producer_tree [ "repos/masc/lib"; "repos/masc/test" ]

let sample_schemas = [ "lookup_read"; "lookup_list" ]

let make_original ~verification_id ~attempt =
  match
    V.prepare ~generator_runtime:(Some "captured-producer")
      ~verification_id
      ~attempt
      ~question:sample_question
      ~lookup_root:sample_root
      ~lookup_binding:(String.make 64 'a')
      ~lookup_schemas:sample_schemas
      sample_request
  with
  | Ok original -> original
  | Error detail -> failwith ("prepare failed: " ^ detail)

let test_round_trip_preserves_lookup_and_image () =
  let original = make_original ~verification_id:"vrf-test" ~attempt:0 in
  let restored = match V.of_json (V.to_json original) with
    | Ok value -> value
    | Error detail -> failwith ("of_json failed: " ^ detail)
  in
  assert (V.generator_runtime restored = Some "captured-producer");
  assert (V.generator_runtime (match V.successor restored with Ok v -> v | Error e -> failwith e) = Some "captured-producer");
  (* lookup grants survive the round trip *)
  (match V.lookup_root restored with
   | AR.Producer_tree paths -> assert (paths = [ "repos/masc/lib"; "repos/masc/test" ])
   | _ -> failwith "lookup_root did not survive round trip");
  assert (V.lookup_schemas restored = sample_schemas);
  (* evidence image survives the round trip byte-for-byte *)
  let req = V.review_request restored in
  (match req.evidence_images with
   | [ image ] ->
     assert (image.image_reference = sample_image.image_reference);
     assert (image.image_sha256 = sample_image.image_sha256);
     assert (image.image_bytes = sample_image.image_bytes);
     assert (image.image_media_type = sample_image.image_media_type);
     assert (image.image_body_base64 = sample_image.image_body_base64)
   | _ -> failwith "evidence image did not survive round trip");
  (* digest is stable across the round trip *)
  let d1 = match V.digest original with Ok d -> d | Error e -> failwith e in
  let d2 = match V.digest restored with Ok d -> d | Error e -> failwith e in
  assert (String.equal d1 d2)

let test_other_verification_original_is_rejected () =
  (* an original prepared for one verification must not apply to a different
     attempt: the identity lives in the value, so reusing its pieces under a
     different verification_id is a different original. *)
  let original = make_original ~verification_id:"vrf-aaaa" ~attempt:0 in
  let json = V.to_json original in
  (* re-tag the same bytes under a different verification_id *)
  let retagged = match json with
    | `Assoc fields ->
      `Assoc (List.map (fun (k, v) -> if k = "verification_id" then k, `String "vrf-bbbb" else k, v) fields)
    | _ -> failwith "unexpected json"
  in
  match V.of_json retagged with
  | Ok other ->
    (* parsing succeeds but the identity differs, so the digest differs and
       the value cannot be passed off as the first verification's original *)
    let d1 = match V.digest original with Ok d -> d | Error e -> failwith e in
    let d2 = match V.digest other with Ok d -> d | Error e -> failwith e in
    assert (not (String.equal d1 d2));
    assert (not (String.equal (V.verification_id other) (V.verification_id original)))
  | Error detail -> failwith ("of_json rejected retagged original: " ^ detail)

let test_round_trip_with_blank_notes () =
  (* the runtime can carry an empty completion_notes, so a stored original
     must read back the same blank string rather than reject it. *)
  let blank_request : AR.review_request = { sample_request with completion_notes = "" } in
  let original =
    match
      V.prepare ~generator_runtime:None
        ~verification_id:"vrf-blank"
        ~attempt:0
        ~question:sample_question
        ~lookup_root:sample_root
        ~lookup_binding:(String.make 64 'a')
      ~lookup_schemas:sample_schemas
        blank_request
    with
    | Ok original -> original
    | Error detail -> failwith ("prepare with blank notes failed: " ^ detail)
  in
  match V.of_json (V.to_json original) with
  | Ok restored ->
    assert ((V.review_request restored).completion_notes = "")
  | Error detail -> failwith ("blank completion_notes must round trip: " ^ detail)

let test_unknown_field_rejected () =
  let original = make_original ~verification_id:"vrf-cccc" ~attempt:0 in
  let json = match V.to_json original with
    | `Assoc fields -> `Assoc (("extra", `String "x") :: fields)
    | _ -> failwith "unexpected json"
  in
  match V.of_json json with
  | Ok _ -> failwith "unknown field must be rejected"
  | Error _ -> ()

let test_missing_field_rejected () =
  let original = make_original ~verification_id:"vrf-dddd" ~attempt:0 in
  let json = match V.to_json original with
    | `Assoc fields -> `Assoc (List.filter (fun (k, _) -> k <> "lookup_schemas") fields)
    | _ -> failwith "unexpected json"
  in
  match V.of_json json with
  | Ok _ -> failwith "missing field must be rejected"
  | Error _ -> ()

let test_empty_lookup_schemas_rejected () =
  match
    V.prepare ~generator_runtime:None
      ~verification_id:"vrf-eeee"
      ~attempt:0
      ~question:sample_question
      ~lookup_root:sample_root
      ~lookup_binding:(String.make 64 'a')
      ~lookup_schemas:[]
      sample_request
  with
  | Ok _ -> failwith "empty lookup_schemas must be rejected"
  | Error _ -> ()

let test_namespace_round_trip_and_strict_decode () =
  let original = match V.prepare ~generator_runtime:None
    ~verification_id:"vrf-namespace" ~attempt:0 ~question:sample_question
    ~lookup_root:(AR.Producer_namespace {root="/owned/root"})
    ~lookup_binding:(String.make 64 'a') ~lookup_schemas:sample_schemas sample_request with
    | Ok value -> value | Error detail -> failwith detail in
  let json = V.to_json original in
  (match V.of_json json with
   | Ok value -> assert (V.lookup_root value = AR.Producer_namespace {root="/owned/root"})
   | Error detail -> failwith detail);
  List.iter (fun invalid ->
    let bad = match json with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
          key, if key="lookup_root" then invalid else value) fields)
      | _ -> assert false in
    match V.of_json bad with
    | Error _ -> () | Ok _ -> failwith "invalid namespace decoded")
    [`Assoc ["producer_namespace", `String ""];
     `Assoc ["producer_namespace", `String "/owned/root";"producer_tree", `List []];
     `Assoc ["producer_namespace", `String "/owned/root";"producer_namespace", `String "/other"]]

let () =
  test_namespace_round_trip_and_strict_decode ();
  test_round_trip_preserves_lookup_and_image ();
  test_round_trip_with_blank_notes ();
  test_other_verification_original_is_rejected ();
  test_unknown_field_rejected ();
  test_missing_field_rejected ();
  test_empty_lookup_schemas_rejected ();
  print_endline "test_verifier_review_original: all tests passed"
