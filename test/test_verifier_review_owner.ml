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

let prepare_original ~request ~verification_id ~attempt =
  match
    V.prepare ~generator_runtime:None
      ~verification_id
      ~attempt
      ~question:sample_question
      ~lookup_root:sample_root
      ~lookup_binding:(String.make 64 'a')
      ~lookup_schemas:sample_schemas
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
let expect_scope_error = function
  | Error (O.Corrupt_original _ | O.Load_store_unavailable _) -> ()
  | Error O.Not_found | Ok _ -> failwith "unverifiable inventory must not prove absence or a fresh attempt"

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
  expect_scope_error (selected_next store "other:attempt-7");
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
    expect_scope_error (selected_next store "independent")) cases

let test_target_corruption_and_unreadable_foreign_body_are_not_absence () =
  with_workspace (fun base_path ->
    let store=tmp_store base_path in
    ignore (routing_fixture ~supported:true ~body_edit:(replace_field "generator_runtime" (`String " "))
      store ~key_id:"target" ~summary_id:"target" ~body_id:"target" ());
    expect_scope_error (selected_next store "target"));
  List.iter (fun replacement -> with_workspace @@ fun base_path ->
    let store=tmp_store base_path in
    let _,digest=routing_fixture store ~key_id:"foreign" ~summary_id:"foreign" ~body_id:"foreign" () in
    let path=Filename.concat (Store.root store)
      (Filename.concat "tool-request-bodies" (Filename.concat (Store.digest fixture_scope) (digest^".json"))) in
    Sys.remove path;
    if replacement then Unix.mkdir path 0o700;
    expect_scope_error (selected_next store "target")) [false;true]

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
    expect_scope_error (selected_next store "target")) [false;true]

let () =
  test_round_trip ();
  test_retain_is_idempotent ();
  test_different_original_at_same_key_rejected ();
  test_different_destination_rejected ();
  test_retry_is_new_attempt ();
  test_load_not_found ();
  test_verification_selection_preserves_unsupported_foreign_original ();
  test_foreign_routing_requires_independent_key_header_and_body ();
  test_target_corruption_and_unreadable_foreign_body_are_not_absence ();
  test_duplicate_metadata_cannot_hide_a_target ();
  print_endline "test_verifier_review_owner: all tests passed"
