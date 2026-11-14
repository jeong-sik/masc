module AR = Masc.Task.Anti_rationalization
module V = Masc.Verifier_review_original
module O = Masc.Verifier_review_owner

let string_of_retain_error = function
  | O.Original_invalid detail -> "Original_invalid: " ^ detail
  | O.Identity_mismatch detail -> "Identity_mismatch: " ^ detail
  | O.Retain_store_unavailable detail -> "Retain_store_unavailable: " ^ detail
  | O.Already_retained request_id -> "Already_retained: " ^ request_id
;;

let string_of_load_error = function
  | O.Load_store_unavailable detail -> "Load_store_unavailable: " ^ detail
  | O.Not_found -> "Not_found"
  | O.Corrupt_original detail -> "Corrupt_original: " ^ detail
;;

let sample_image : AR.evidence_image =
  { image_reference = "artifact:evidence/shot.png"
  ; image_sha256 = "def456"
  ; image_bytes = 7
  ; image_media_type = "image/png"
  ; image_body_base64 = "d29ybGQ="
  }

let sample_request : AR.review_request =
  { task_title = "Task"
  ; task_description = "Desc"
  ; completion_notes = "Notes"
  ; agent_name = "agent"
  ; task_id = "task-1"
  ; evidence_refs = [ "note:a" ]
  ; evidence_images = [ sample_image ]
  }

let sample_question : AR.verdict_question =
  { completion_contract = None
  ; required_evidence = [ "green" ]
  ; evidence_posture = AR.Note_only
  ; few_shot_block = ""
  }

let sample_root : AR.lookup_root = AR.Producer_tree [ "a"; "b" ]
let sample_schemas = [ "lookup_read" ]

let sample_lookup : V.lookup =
  { V.granted_root = sample_root
  ; granted_tools = sample_schemas
  ; question_digest = String.make 64 'a'
  ; authority_digest = String.make 64 'b'
  }

let prepare_original ~request ~verification_id ~attempt =
  match
    V.prepare ~generator_runtime:None
      ~verification_id
      ~attempt
      ~question:sample_question
      ~lookup:sample_lookup
      request
  with
  | Ok original -> original
  | Error detail -> failwith ("prepare failed: " ^ detail)

let make_original ~verification_id ~attempt =
  prepare_original ~request:sample_request ~verification_id ~attempt

let with_workspace f =
  let base_path = Filename.temp_dir "verifier-owner-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path; Fs_compat.clear_fs ())
    (fun () -> f base_path)

let tmp_store base_path =
  Masc.Lane_addon_store.create ~root:(Filename.concat base_path "request-ownership")

let test_round_trip () =
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  let original = make_original ~verification_id:"vrf-x" ~attempt:0 in
  (match O.retain ~store ~verification_id:"vrf-x" ~attempt:0 ~installation_id:"masc.verifier" ~package_id:"masc.verifier.review" original with
   | Ok () -> ()
   | Error err -> failwith ("retain failed: " ^ string_of_retain_error err));
  match O.load ~store ~verification_id:"vrf-x" ~attempt:0 with
  | Ok loaded ->
    assert (V.verification_id loaded = "vrf-x");
    assert (V.attempt loaded = 0);
    (match V.lookup_root loaded with
     | AR.Producer_tree paths -> assert (paths = [ "a"; "b" ])
     | _ -> failwith "lookup_root not preserved");
    let req = V.review_request loaded in
    (match req.evidence_images with
     | [ img ] -> assert (img.image_sha256 = "def456")
     | _ -> failwith "evidence image not preserved")
  | Error err -> failwith ("load failed after retain: " ^ string_of_load_error err)

let test_retain_is_idempotent () =
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  let original = make_original ~verification_id:"vrf-y" ~attempt:0 in
  let once = O.retain ~store ~verification_id:"vrf-y" ~attempt:0 ~installation_id:"i" ~package_id:"p" original in
  let twice = O.retain ~store ~verification_id:"vrf-y" ~attempt:0 ~installation_id:"i" ~package_id:"p" original in
  (match once, twice with
   | Ok (), Ok () -> ()
   | _ -> failwith "same original should retain idempotently")

let test_different_original_at_same_key_rejected () =
  (* The conflict is about the same attempt slot holding a different body.
     Keep verification_id and attempt identical and change only the request
     body, so the conflict is [Already_retained], not [Identity_mismatch]. *)
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  let first = make_original ~verification_id:"vrf-z" ~attempt:0 in
  let different =
    prepare_original
      ~request:{ sample_request with AR.task_description = "Different original" }
      ~verification_id:"vrf-z"
      ~attempt:0
  in
  (match O.retain ~store ~verification_id:"vrf-z" ~attempt:0 ~installation_id:"i" ~package_id:"p" first with
   | Ok () -> ()
   | Error err -> failwith ("first retain failed: " ^ string_of_retain_error err));
  (match O.retain ~store ~verification_id:"vrf-z" ~attempt:0 ~installation_id:"i" ~package_id:"p" different with
   | Ok () -> failwith "different body at same key must be rejected as Already_retained"
   | Error (O.Already_retained _) -> ()
   | Error err -> failwith ("wrong rejection: " ^ string_of_retain_error err));
  (* the original body must still be the one stored, not the rejected body *)
  (match O.load ~store ~verification_id:"vrf-z" ~attempt:0 with
   | Ok loaded ->
     let req = V.review_request loaded in
     assert (req.AR.task_description = "Desc")
   | Error err -> failwith ("readback after conflict failed: " ^ string_of_load_error err))

let test_retry_is_new_attempt () =
  (* a retry under a fresh attempt key must not clobber the prior attempt *)
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  let first = make_original ~verification_id:"vrf-r" ~attempt:0 in
  (match O.retain ~store ~verification_id:"vrf-r" ~attempt:0 ~installation_id:"i" ~package_id:"p" first with
   | Ok () -> ()
   | Error err -> failwith ("retain attempt 0 failed: " ^ string_of_retain_error err));
  (* attempt 1 is a different key, so it stores independently *)
  let retried = make_original ~verification_id:"vrf-r" ~attempt:1 in
  (match O.retain ~store ~verification_id:"vrf-r" ~attempt:1 ~installation_id:"i" ~package_id:"p" retried with
   | Ok () -> ()
   | Error err -> failwith ("retain attempt 1 failed: " ^ string_of_retain_error err));
  (* both are readable independently *)
  (match O.load ~store ~verification_id:"vrf-r" ~attempt:0 with
   | Ok v -> assert (V.attempt v = 0)
   | Error err -> failwith ("attempt 0 lost: " ^ string_of_load_error err));
  (match O.load ~store ~verification_id:"vrf-r" ~attempt:1 with
   | Ok v -> assert (V.attempt v = 1)
   | Error err -> failwith ("attempt 1 lost: " ^ string_of_load_error err))

let test_load_not_found () =
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  match O.load ~store ~verification_id:"vrf-none" ~attempt:0 with
  | Error O.Not_found -> ()
  | _ -> failwith "absent key must be Not_found"

let test_different_destination_rejected () =
  (* The durable owner compares the whole record, not just the request body.
     Retaining the same original under a different installation or package
     must not silently pass: it is an [Already_retained] conflict, never an
     overwrite of the first destination. *)
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  let original = make_original ~verification_id:"vrf-d" ~attempt:0 in
  (match O.retain ~store ~verification_id:"vrf-d" ~attempt:0 ~installation_id:"masc.verifier" ~package_id:"masc.verifier.review" original with
   | Ok () -> ()
   | Error err -> failwith ("first retain failed: " ^ string_of_retain_error err));
  (match O.retain ~store ~verification_id:"vrf-d" ~attempt:0 ~installation_id:"other.install" ~package_id:"masc.verifier.review" original with
  | Ok () -> failwith "same original under a different installation must not pass"
  | Error (O.Already_retained _) -> ()
  | Error err -> failwith ("wrong rejection: " ^ string_of_retain_error err));
  (* the first destination must still accept the same original afterwards *)
  (match O.retain ~store ~verification_id:"vrf-d" ~attempt:0 ~installation_id:"masc.verifier" ~package_id:"masc.verifier.review" original with
   | Ok () -> ()
   | Error err -> failwith ("original destination must still accept after rejected overwrite: " ^ string_of_retain_error err))

module Raw_owner = Masc.Lane_addon_tool_request_owner
module Store = Masc.Lane_addon_store
let fixture_scope = "verifier-reviews"
let fixture_get = function Ok value -> value | Error _ -> failwith "routing fixture preparation failed"
let replace_field key value = function
  | `Assoc fields -> `Assoc (List.map (fun (name,old) -> name,if name=key then value else old) fields)
  | _ -> assert false

let routing_fixture ?(summary_edit=Fun.id) ?(body_edit=Fun.id) ?(supported=false)
    store ~key_id ~summary_id ~body_id () =
  let original = make_original ~verification_id:body_id ~attempt:0 in
  let request = if supported then V.to_json original else
    replace_field "schema" (`String "unrecognised-review-original") (V.to_json original) in
  let request = body_edit request in
  let request = fixture_get (Masc.Lane_addon_action.canonical request) in
  let digest = fixture_get (Raw_owner.request_digest request) in
  let schema = Yojson.Safe.Util.member "schema" request in
  let summary = summary_edit (`Assoc ["schema",schema;"verification_id",`String summary_id;
    "attempt",`Int 0;"original_digest",`String digest]) in
  let request_id = fixture_get (O.attempt_request_id ~verification_id:key_id ~attempt:0) in
  (match Raw_owner.retain ~store ~scope:fixture_scope ~request_id ~installation_id:"i"
      ~package_id:"p" ~tool:"verifier_review" ~summary ~request with
   | Ok () -> () | Error _ -> failwith "raw routing fixture retain failed");
  request_id,digest

let selected_next store id = O.next_attempt ~store ~verification_id:id ~installation_id:"i" ~package_id:"p"
  ~lookup:(fun () -> Error "inventory selection must not prepare lookup authority")
let expect_scope_error = function
  | Error (O.Corrupt_original _ | O.Load_store_unavailable _) -> ()
  | Error O.Not_found | Ok _ -> failwith "unverifiable inventory must not prove absence or a fresh attempt"
let expect_next_scope_error = function
  | Error (O.Load (O.Corrupt_original _ | O.Load_store_unavailable _)) -> ()
  | Error (O.Load O.Not_found | O.Lookup_unavailable _ | O.Question_changed) | Ok _ ->
    failwith "unverifiable inventory must not prove absence or a fresh attempt"

let test_verification_selection_preserves_unsupported_foreign_original () =
  with_workspace @@ fun base_path ->
  let store=tmp_store base_path in
  let key,_=routing_fixture store ~key_id:"other:attempt-7" ~summary_id:"other:attempt-7"
    ~body_id:"other:attempt-7" () in
  let before=fixture_get (Raw_owner.load ~store ~scope:fixture_scope ~request_id:key) |> Option.get in
  let target=make_original ~verification_id:"target" ~attempt:0 in
  (match O.retain ~store ~verification_id:"target" ~attempt:0 ~installation_id:"i" ~package_id:"p" target with
   | Ok () -> () | Error _ -> failwith "target retain failed");
  assert (selected_next store "target"=Ok 0);
  assert (selected_next store "fresh-target"=Ok 0);
  assert (O.retained_commits ~store ~selection:(O.Verification "target") ~installation_id:"i" ~package_id:"p"=Ok []);
  assert (O.pending_commits ~store ~selection:(O.Verification "target") ~terminal_pending:(fun _ -> Ok false)
    ~installation_id:"i" ~package_id:"p"=Ok []);
  expect_scope_error (O.load ~store ~verification_id:"other:attempt-7" ~attempt:0);
  expect_next_scope_error (selected_next store "other:attempt-7");
  expect_scope_error (O.retained_commits ~store ~selection:O.All_verifications ~installation_id:"i" ~package_id:"p");
  expect_scope_error (O.pending_commits ~store ~selection:O.All_verifications ~terminal_pending:(fun _ -> Ok false)
    ~installation_id:"i" ~package_id:"p");
  let after=fixture_get (Raw_owner.load ~store ~scope:fixture_scope ~request_id:key) |> Option.get in
  assert (before=after)

let test_foreign_routing_requires_independent_key_header_and_body () =
  let cases = [
    "summary identity", "a", "b", "a", replace_field "attempt" (`Int 0), Fun.id;
    "body identity", "a", "a", "b", Fun.id, Fun.id;
    "record key", "wrong-key", "a", "a", Fun.id, Fun.id;
    "schema", "a", "a", "a", replace_field "schema" (`String "another-format"), Fun.id;
    "digest", "a", "a", "a", replace_field "original_digest" (`String (String.make 64 '0')), Fun.id;
    "attempt", "a", "a", "a", replace_field "attempt" (`Int 1), Fun.id;
    "missing summary ID", "a", "a", "a",
      (function `Assoc fs -> `Assoc (List.remove_assoc "verification_id" fs) | _ -> assert false), Fun.id;
    "missing body ID", "a", "a", "a", Fun.id,
      (function `Assoc fs -> `Assoc (List.remove_assoc "verification_id" fs) | _ -> assert false);
    "malformed body attempt", "a", "a", "a", Fun.id, replace_field "attempt" (`Bool false)
  ] in
  List.iter (fun (_label,key_id,summary_id,body_id,summary_edit,body_edit) ->
    with_workspace @@ fun base_path ->
    let store=tmp_store base_path in
    ignore (routing_fixture ~summary_edit ~body_edit store ~key_id ~summary_id ~body_id ());
    expect_next_scope_error (selected_next store "independent")) cases

let test_target_corruption_and_unreadable_foreign_body_are_not_absence () =
  with_workspace (fun base_path ->
    let store=tmp_store base_path in
    ignore (routing_fixture ~supported:true ~body_edit:(replace_field "generator_runtime" (`String " "))
      store ~key_id:"target" ~summary_id:"target" ~body_id:"target" ());
    expect_next_scope_error (selected_next store "target"));
  List.iter (fun replacement -> with_workspace @@ fun base_path ->
    let store=tmp_store base_path in
    let _,digest=routing_fixture store ~key_id:"foreign" ~summary_id:"foreign" ~body_id:"foreign" () in
    let path=Filename.concat (Store.root store)
      (Filename.concat "tool-request-bodies" (Filename.concat (Store.digest fixture_scope) (digest^".json"))) in
    Sys.remove path;
    if replacement then Unix.mkdir path 0o700;
    expect_next_scope_error (selected_next store "target")) [false;true]

let test_duplicate_metadata_cannot_hide_a_target () =
  List.iter (fun body_duplicate -> with_workspace @@ fun base_path ->
    let store=tmp_store base_path in
    let request_id,digest=routing_fixture store ~key_id:"foreign" ~summary_id:"foreign" ~body_id:"foreign" () in
    let record=fixture_get (Store.load_tool_request_owner store ~scope:fixture_scope ~request_id) |> Option.get in
    let summary=Yojson.Safe.Util.member "summary" record in
    let record=if not body_duplicate then
      let duplicate=match summary with
        | `Assoc fields -> `Assoc (("verification_id",`String "target")::fields)
        | _ -> assert false in
      replace_field "summary" duplicate record
    else
      let bytes=fixture_get (Store.load_tool_request_body store ~scope:fixture_scope ~request_digest:digest) |> Option.get in
      let body=match Yojson.Safe.from_string bytes with
        | `Assoc fields -> `Assoc (("verification_id",`String "target")::fields)
        | _ -> assert false in
      let bytes=Yojson.Safe.to_string body in
      let request_digest=Store.digest bytes in
      ignore (fixture_get (Store.save_tool_request_body store ~scope:fixture_scope ~request_digest bytes));
      record |> replace_field "request_digest" (`String request_digest)
        |> replace_field "summary" (replace_field "original_digest" (`String request_digest) summary) in
    ignore (fixture_get (Store.save_tool_request_owner store ~scope:fixture_scope ~request_id record));
    expect_next_scope_error (selected_next store "target")) [false;true]

module Progress = Masc.Lane_addon_request_progress

(* The lookup authority current at the next attempt: other tools, another
   root and another authority digest for the same question. *)
let current_lookup : V.lookup =
  { V.granted_root = AR.Producer_namespace { root = "/current" }
  ; granted_tools = [ "lookup_read"; "lookup_grep" ]
  ; question_digest = sample_lookup.question_digest
  ; authority_digest = String.make 64 'c'
  }

(* A definite execution refusal that names one runtime to review again. *)
let definite_refusal =
  let result : AR.review_result =
    { AR.verdict = None
    ; evaluator_runtime = "rt-a"
    ; generator_runtime = None
    ; evaluator_execution = None
    ; gate = AR.Evaluator_unavailable
    ; fallback_reason = Some "the reviewer refused before reporting"
    ; retryable_runtimes = [ "rt-a" ]
    ; model_absent_runtimes = []
    }
  in
  `Assoc
    [ "schema", `String "verifier_review_refusal/v1"
    ; "certainty", `String "definite"
    ; "observations", `List [ `Assoc [ "fact", `String "definite_refusal"
        ; "runtime_id", `String "rt-a"; "error_category", `String "provider" ] ]
    ; "result", O.result_to_json result
    ]

let loaded_or_fail = function
  | Ok value -> value
  | Error err -> failwith (string_of_load_error err)

let refused_first ~store ~verification_id =
  let original = make_original ~verification_id ~attempt:0 in
  (match O.retain ~store ~verification_id ~attempt:0 ~installation_id:"i" ~package_id:"p" original with
   | Ok () -> ()
   | Error err -> failwith ("retain failed: " ^ string_of_retain_error err));
  let retained = loaded_or_fail
    (O.load_retained ~store ~verification_id ~attempt:0 ~installation_id:"i" ~package_id:"p") in
  ignore (loaded_or_fail (O.advance_events ~store retained
    [ Progress.Dispatch_intended
    ; Progress.Refused { stage = Progress.Execution; evidence = definite_refusal } ]));
  original

let next_with ~lookup store verification_id =
  O.next_attempt ~store ~verification_id ~installation_id:"i" ~package_id:"p" ~lookup

let must_not_prepare () = Error "restoring an attempt must not prepare lookup authority"

let test_retry_successor_asks_with_current_lookup () =
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  let parent = refused_first ~store ~verification_id:"vrf-next" in
  let prepared = ref 0 in
  let lookup () = incr prepared; Ok current_lookup in
  assert (next_with ~lookup store "vrf-next" = Ok 1);
  assert (!prepared = 1);
  let child = loaded_or_fail (O.load ~store ~verification_id:"vrf-next" ~attempt:1) in
  assert (V.is_successor_of ~parent child);
  assert (String.equal (V.question_binding child) (V.question_binding parent));
  assert (String.equal (V.authority_binding child) current_lookup.authority_digest);
  assert (V.lookup_schemas child = current_lookup.granted_tools);
  assert (V.lookup_root child = current_lookup.granted_root);
  (* the next wake restores attempt 1 without preparing authority again *)
  assert (next_with ~lookup:must_not_prepare store "vrf-next" = Ok 1)

let test_retry_with_a_changed_question_opens_nothing () =
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  ignore (refused_first ~store ~verification_id:"vrf-moved");
  let moved = { current_lookup with V.question_digest = String.make 64 'd' } in
  (match next_with ~lookup:(fun () -> Ok moved) store "vrf-moved" with
   | Error O.Question_changed -> ()
   | Ok _ | Error (O.Load _ | O.Lookup_unavailable _) ->
     failwith "a changed question must not open the next attempt");
  (match O.load ~store ~verification_id:"vrf-moved" ~attempt:1 with
   | Error O.Not_found -> ()
   | Ok _ | Error _ -> failwith "no next attempt may be retained for a changed question");
  let parent = loaded_or_fail
    (O.load_retained ~store ~verification_id:"vrf-moved" ~attempt:0 ~installation_id:"i" ~package_id:"p") in
  match Progress.phase (O.progress parent) with
  | Progress.Rejected { stage = Progress.Execution; _ } -> ()
  | _ -> failwith "the refused attempt must stay refused"

let test_retry_without_lookup_authority_opens_nothing () =
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  ignore (refused_first ~store ~verification_id:"vrf-down");
  (match next_with ~lookup:(fun () -> Error "route unavailable") store "vrf-down" with
   | Error (O.Lookup_unavailable "route unavailable") -> ()
   | Ok _ | Error (O.Load _ | O.Lookup_unavailable _ | O.Question_changed) ->
     failwith "unavailable lookup authority must not open the next attempt");
  match O.load ~store ~verification_id:"vrf-down" ~attempt:1 with
  | Error O.Not_found -> ()
  | Ok _ | Error _ -> failwith "no next attempt may be retained without lookup authority"

let test_intended_successor_is_restored_without_preparing_authority () =
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  let parent = refused_first ~store ~verification_id:"vrf-cut" in
  (* The process stopped after the parent recorded its successor intent and
     before the child was retained. *)
  let child = match V.successor ~lookup:current_lookup parent with
    | Ok child -> child
    | Error _ -> failwith "successor fixture failed" in
  let request_id = fixture_get (O.attempt_request_id ~verification_id:"vrf-cut" ~attempt:1) in
  let successor = fixture_get
    (Raw_owner.prepare_successor ~store ~scope:O.scope ~request_id ~request:(V.to_json child)) in
  let retained = loaded_or_fail
    (O.load_retained ~store ~verification_id:"vrf-cut" ~attempt:0 ~installation_id:"i" ~package_id:"p") in
  ignore (loaded_or_fail (O.advance ~store retained (Progress.Successor_intended successor)));
  assert (next_with ~lookup:must_not_prepare store "vrf-cut" = Ok 1);
  let restored = loaded_or_fail (O.load ~store ~verification_id:"vrf-cut" ~attempt:1) in
  assert (Yojson.Safe.equal (V.to_json restored) (V.to_json child))

module Change = Masc.Verifier_review_authority_change

(* The worker recorded a before-dispatch refusal and the process stopped before
   any successor intent. *)
let refused_before_dispatch ~store ~verification_id evidence =
  let original = make_original ~verification_id ~attempt:0 in
  (match O.retain ~store ~verification_id ~attempt:0 ~installation_id:"i" ~package_id:"p" original with
   | Ok () -> ()
   | Error err -> failwith ("retain failed: " ^ string_of_retain_error err));
  let retained = loaded_or_fail
    (O.load_retained ~store ~verification_id ~attempt:0 ~installation_id:"i" ~package_id:"p") in
  ignore (loaded_or_fail (O.advance ~store retained
    (Progress.Refused { stage = Progress.Before_dispatch; evidence })));
  original

(* The evidence the worker records when an attempt that held [from] meets the
   current lookup authority under an unchanged answer format. *)
let authority_moved ?(from = sample_lookup.authority_digest) () =
  let format = V.canonical_output_contract () in
  match Change.between ~retained_authority:from ~current_authority:current_lookup.authority_digest
      ~retained_format:format ~current_format:format with
  | Ok (Some change) -> Change.to_json change
  | Ok None | Error _ -> failwith "the change fixture moved nothing"

let test_before_dispatch_refusal_opens_the_next_attempt_with_current_lookup () =
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  let parent = refused_before_dispatch ~store ~verification_id:"vrf-moved" (authority_moved ()) in
  assert (next_with ~lookup:(fun () -> Ok current_lookup) store "vrf-moved" = Ok 1);
  let child = loaded_or_fail (O.load ~store ~verification_id:"vrf-moved" ~attempt:1) in
  assert (V.is_successor_of ~parent child);
  assert (String.equal (V.authority_binding child) current_lookup.authority_digest);
  assert (V.lookup_schemas child = current_lookup.granted_tools);
  let refused = loaded_or_fail
    (O.load_retained ~store ~verification_id:"vrf-moved" ~attempt:0 ~installation_id:"i" ~package_id:"p") in
  (match Progress.phase (O.progress refused) with
   | Progress.Subdivided ({ stage = Progress.Before_dispatch; _ }, _) -> ()
   | _ -> failwith "the refused attempt must link its next attempt");
  assert (next_with ~lookup:must_not_prepare store "vrf-moved" = Ok 1)

let test_unreadable_before_dispatch_refusal_opens_nothing () =
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  ignore (refused_before_dispatch ~store ~verification_id:"vrf-unread"
    (`Assoc [ "reason", `String "no closed change" ]));
  (match next_with ~lookup:(fun () -> Ok current_lookup) store "vrf-unread" with
   | Error (O.Load (O.Corrupt_original _)) -> ()
   | Ok _ | Error (O.Load (O.Not_found | O.Load_store_unavailable _) | O.Lookup_unavailable _
     | O.Question_changed) ->
     failwith "an unreadable before-dispatch refusal must not open the next attempt");
  match O.load ~store ~verification_id:"vrf-unread" ~attempt:1 with
  | Error O.Not_found -> ()
  | Ok _ | Error _ -> failwith "no next attempt may be retained for an unreadable refusal"

let test_before_dispatch_refusal_from_another_original_opens_nothing () =
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  ignore (refused_before_dispatch ~store ~verification_id:"vrf-foreign"
    (authority_moved ~from:(String.make 64 'e') ()));
  (match next_with ~lookup:(fun () -> Ok current_lookup) store "vrf-foreign" with
   | Error (O.Load (O.Corrupt_original _)) -> ()
   | Ok _ | Error (O.Load (O.Not_found | O.Load_store_unavailable _) | O.Lookup_unavailable _
     | O.Question_changed) ->
     failwith "a refusal that starts at another original must not open the next attempt");
  match O.load ~store ~verification_id:"vrf-foreign" ~attempt:1 with
  | Error O.Not_found -> ()
  | Ok _ | Error _ -> failwith "no next attempt may be retained for another original's refusal"

let test_intended_successor_after_a_before_dispatch_refusal_is_restored () =
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  let parent = refused_before_dispatch ~store ~verification_id:"vrf-cut-moved" (authority_moved ()) in
  (* The process stopped after the refused attempt recorded its successor
     intent and before the child was retained. *)
  let child = match V.successor ~lookup:current_lookup parent with
    | Ok child -> child
    | Error _ -> failwith "successor fixture failed" in
  let request_id = fixture_get (O.attempt_request_id ~verification_id:"vrf-cut-moved" ~attempt:1) in
  let successor = fixture_get
    (Raw_owner.prepare_successor ~store ~scope:O.scope ~request_id ~request:(V.to_json child)) in
  let retained = loaded_or_fail
    (O.load_retained ~store ~verification_id:"vrf-cut-moved" ~attempt:0 ~installation_id:"i" ~package_id:"p") in
  ignore (loaded_or_fail (O.advance ~store retained (Progress.Successor_intended successor)));
  assert (next_with ~lookup:must_not_prepare store "vrf-cut-moved" = Ok 1);
  let restored = loaded_or_fail (O.load ~store ~verification_id:"vrf-cut-moved" ~attempt:1) in
  assert (Yojson.Safe.equal (V.to_json restored) (V.to_json child))

let test_negative_attempt_is_a_wrong_key_for_every_entry () =
  (* No attempt has a negative number, so the key is what is wrong and asking
     again cannot help. [retain] says so as [Identity_mismatch]; every read
     must land on its own "the input is wrong" side, [Corrupt_original], and
     never on the store failure a caller waits out. *)
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  let original = make_original ~verification_id:"vrf-neg" ~attempt:0 in
  (match O.retain ~store ~verification_id:"vrf-neg" ~attempt:(-1) ~installation_id:"i" ~package_id:"p" original with
   | Error (O.Identity_mismatch _) -> ()
   | Ok () -> failwith "a negative attempt key must not retain"
   | Error err -> failwith ("wrong retain rejection: " ^ string_of_retain_error err));
  let wrong_key name = function
    | Error (O.Corrupt_original _) -> ()
    | Ok _ -> failwith (name ^ ": a negative attempt key must not load")
    | Error err -> failwith (name ^ ": wrong rejection: " ^ string_of_load_error err) in
  wrong_key "load" (O.load ~store ~verification_id:"vrf-neg" ~attempt:(-1));
  wrong_key "load_for_destination"
    (O.load_for_destination ~store ~verification_id:"vrf-neg" ~attempt:(-1)
       ~installation_id:"i" ~package_id:"p");
  wrong_key "load_retained"
    (O.load_retained ~store ~verification_id:"vrf-neg" ~attempt:(-1)
       ~installation_id:"i" ~package_id:"p")

let () =
  test_before_dispatch_refusal_opens_the_next_attempt_with_current_lookup ();
  test_unreadable_before_dispatch_refusal_opens_nothing ();
  test_before_dispatch_refusal_from_another_original_opens_nothing ();
  test_intended_successor_after_a_before_dispatch_refusal_is_restored ();
  test_retry_successor_asks_with_current_lookup ();
  test_retry_with_a_changed_question_opens_nothing ();
  test_retry_without_lookup_authority_opens_nothing ();
  test_intended_successor_is_restored_without_preparing_authority ();
  test_round_trip ();
  test_retain_is_idempotent ();
  test_different_original_at_same_key_rejected ();
  test_different_destination_rejected ();
  test_retry_is_new_attempt ();
  test_load_not_found ();
  test_negative_attempt_is_a_wrong_key_for_every_entry ();
  test_verification_selection_preserves_unsupported_foreign_original ();
  test_foreign_routing_requires_independent_key_header_and_body ();
  test_target_corruption_and_unreadable_foreign_body_are_not_absence ();
  test_duplicate_metadata_cannot_hide_a_target ();
  print_endline "test_verifier_review_owner: all tests passed"
