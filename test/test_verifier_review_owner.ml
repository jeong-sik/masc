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

let make_original ~verification_id ~attempt =
  match
    V.prepare
      ~verification_id
      ~attempt
      ~question:sample_question
      ~lookup_root:sample_root
      ~lookup_schemas:sample_schemas
      sample_request
  with
  | Ok original -> original
  | Error detail -> failwith ("prepare failed: " ^ detail)

let with_workspace f =
  let base_path = Filename.temp_dir "verifier-owner-" "" in
  Fun.protect ~finally:(fun () -> Masc.Fs_compat.remove_tree base_path; Masc.Fs_compat.clear_fs ())
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
  with_workspace @@ fun base_path ->
  let store = tmp_store base_path in
  let first = make_original ~verification_id:"vrf-z" ~attempt:0 in
  (* make a genuinely different original by bumping the attempt field in the value *)
  let different =
    match V.of_json (V.to_json first) with
    | Ok value ->
      (match V.to_json value with
       | `Assoc fields ->
         `Assoc (List.map (fun (k, v) -> if k = "attempt" then k, `Int 1 else k, v) fields)
       | _ -> failwith "unexpected")
    | Error e -> failwith e
  in
  let different =
    match V.of_json different with Ok v -> v | Error e -> failwith e
  in
  (match O.retain ~store ~verification_id:"vrf-z" ~attempt:0 ~installation_id:"i" ~package_id:"p" first with
   | Ok () -> ()
   | Error err -> failwith ("first retain failed: " ^ string_of_retain_error err));
  match O.retain ~store ~verification_id:"vrf-z" ~attempt:0 ~installation_id:"i" ~package_id:"p" different with
  | Ok () -> failwith "different original at same key must be rejected"
  | Error (O.Already_retained _) -> ()
  | Error _ -> ()

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
  match O.retain ~store ~verification_id:"vrf-d" ~attempt:0 ~installation_id:"other.install" ~package_id:"masc.verifier.review" original with
  | Ok () -> failwith "same original under a different installation must not pass"
  | Error (O.Already_retained _) -> ()
  | Error _ -> ()

let () =
  test_round_trip ();
  test_retain_is_idempotent ();
  test_different_original_at_same_key_rejected ();
  test_different_destination_rejected ();
  test_retry_is_new_attempt ();
  test_load_not_found ();
  print_endline "test_verifier_review_owner: all tests passed"
