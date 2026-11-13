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

let sample_lookup : V.lookup =
  { V.granted_root = sample_root
  ; granted_tools = sample_schemas
  ; question_digest = String.make 64 'a'
  ; authority_digest = String.make 64 'b'
  }

let successor_or_fail ~lookup parent =
  match V.successor ~lookup parent with
  | Ok child -> child
  | Error V.Question_changed -> failwith "successor refused the same question"
  | Error (V.Successor_unavailable detail) -> failwith ("successor failed: " ^ detail)

let make_original ~verification_id ~attempt =
  match
    V.prepare ~generator_runtime:(Some "captured-producer")
      ~verification_id
      ~attempt
      ~question:sample_question
      ~lookup:sample_lookup
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
  assert (V.generator_runtime (successor_or_fail ~lookup:sample_lookup restored) = Some "captured-producer");
  (* both digests survive the round trip *)
  assert (String.equal (V.question_binding restored) sample_lookup.question_digest);
  assert (String.equal (V.authority_binding restored) sample_lookup.authority_digest);
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
        ~lookup:sample_lookup
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
      ~lookup:{ sample_lookup with V.granted_tools = [] }
      sample_request
  with
  | Ok _ -> failwith "empty lookup_schemas must be rejected"
  | Error _ -> ()

let test_namespace_round_trip_and_strict_decode () =
  let original = match V.prepare ~generator_runtime:None
    ~verification_id:"vrf-namespace" ~attempt:0 ~question:sample_question
    ~lookup:{ sample_lookup with V.granted_root = AR.Producer_namespace {root="/owned/root"} }
    sample_request with
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

let test_digest_fields_are_strict () =
  let json = V.to_json (make_original ~verification_id:"vrf-digest" ~attempt:0) in
  List.iter (fun key ->
    let bad = match json with
      | `Assoc fields -> `Assoc (List.map (fun (name, value) ->
          name, if name = key then `String "not-a-digest" else value) fields)
      | _ -> failwith "unexpected json" in
    match V.of_json bad with
    | Ok _ -> failwith (key ^ " must be a canonical digest")
    | Error _ -> ())
    [ "question_binding"; "authority_binding" ];
  match V.prepare ~generator_runtime:None ~verification_id:"vrf-digest" ~attempt:0
    ~question:sample_question ~lookup:{ sample_lookup with V.question_digest = "short" }
    sample_request with
  | Ok _ -> failwith "a non-canonical question digest must be rejected"
  | Error _ -> ()

let test_successor_asks_the_parent_question_with_current_lookup () =
  let parent = make_original ~verification_id:"vrf-next" ~attempt:0 in
  let current : V.lookup =
    { V.granted_root = AR.Producer_namespace {root = "/current/root"}
    ; granted_tools = [ "lookup_read"; "lookup_grep"; "lookup_list" ]
    ; question_digest = V.question_binding parent
    ; authority_digest = String.make 64 'c'
    }
  in
  let child = successor_or_fail ~lookup:current parent in
  assert (V.attempt child = 1);
  (* the question and the captured producer runtime come from the parent *)
  assert (String.equal (V.verification_id child) (V.verification_id parent));
  assert (V.review_request child = V.review_request parent);
  assert (V.question child = V.question parent);
  assert (V.generator_runtime child = V.generator_runtime parent);
  assert (String.equal (V.question_binding child) (V.question_binding parent));
  (* the lookup grants, prompt and answer format are the current ones *)
  assert (String.equal (V.authority_binding child) current.authority_digest);
  assert (V.lookup_root child = current.granted_root);
  assert (V.lookup_schemas child = current.granted_tools);
  assert (String.equal (V.output_contract child) (V.canonical_output_contract ()));
  let expected_prompt =
    match V.system_prompt ~lookup_schemas:current.granted_tools ~question:(V.question parent)
      ~lookup_root:current.granted_root (V.review_request parent) with
    | Ok text -> text
    | Error detail -> failwith detail
  in
  assert (String.equal (V.system_prompt_text child) expected_prompt);
  assert (not (String.equal (V.system_prompt_text child) (V.system_prompt_text parent)));
  assert (V.is_successor_of ~parent child)

let test_successor_refuses_a_changed_question () =
  let parent = make_original ~verification_id:"vrf-moved" ~attempt:0 in
  match V.successor ~lookup:{ sample_lookup with V.question_digest = String.make 64 'd' } parent with
  | Error V.Question_changed -> ()
  | Error (V.Successor_unavailable detail) ->
    failwith ("a changed question must be Question_changed: " ^ detail)
  | Ok _ -> failwith "a changed question must not open the next attempt"

let test_is_successor_of_compares_only_the_question () =
  let parent = make_original ~verification_id:"vrf-link" ~attempt:0 in
  let child ?(question = sample_question) ?(generator_runtime = Some "captured-producer")
      ?(attempt = 1) lookup =
    match V.prepare ~generator_runtime ~verification_id:"vrf-link" ~attempt ~question ~lookup
      sample_request with
    | Ok value -> value
    | Error detail -> failwith detail
  in
  let regranted =
    { sample_lookup with V.granted_tools = [ "lookup_read" ]; authority_digest = String.make 64 'e' }
  in
  assert (V.is_successor_of ~parent (child regranted));
  assert (not (V.is_successor_of ~parent (child ~generator_runtime:(Some "another-producer") sample_lookup)));
  assert (not (V.is_successor_of ~parent (child ~attempt:2 sample_lookup)));
  assert (not (V.is_successor_of ~parent
    (child { sample_lookup with V.question_digest = String.make 64 'f' })));
  assert (not (V.is_successor_of ~parent
    (child ~question:{ sample_question with AR.required_evidence = [ "another proof" ] } sample_lookup)))

let () =
  test_digest_fields_are_strict ();
  test_successor_asks_the_parent_question_with_current_lookup ();
  test_successor_refuses_a_changed_question ();
  test_is_successor_of_compares_only_the_question ();
  test_namespace_round_trip_and_strict_decode ();
  test_round_trip_preserves_lookup_and_image ();
  test_round_trip_with_blank_notes ();
  test_other_verification_original_is_rejected ();
  test_unknown_field_rejected ();
  test_missing_field_rejected ();
  test_empty_lookup_schemas_rejected ();
  print_endline "test_verifier_review_original: all tests passed"
