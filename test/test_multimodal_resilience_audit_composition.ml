(* Composition tests for multimodal artifacts, typed recovery, and audit chains.

   Scope:
     1. Multimodal: Workspace receives code (HTML) + image (hero PNG)
        artifacts; image's provenance edge references code.
     2. Resilience: fail closed on untyped error text, then derive a
        Degradation L2 strategy from typed transient evidence.
     3. Shared_audit: chain seven audit envelopes across the scenario
        and verify Merkle integrity; tamper-detect the chain.

   This is deliberately not an E2E test: it exercises the production
   building blocks directly without claiming to cover Keeper, wire, or
   persistence boundaries. *)

module Aid = Shared_types.Artifact_id
module W = Multimodal.Workspace
module A = Multimodal.Artifact
module P = Multimodal.Payload
module R = Resilience.Recovery
module D = Resilience.Degradation
module Env = Shared_audit.Envelope
module S = Shared_audit.Store

let check_bool label b =
  if not b then failwith (Printf.sprintf "%s: false" label)

let check_int label expected actual =
  if expected <> actual then
    failwith
      (Printf.sprintf "%s: expected %d, got %d" label expected actual)

(* ── Phase 2: Multimodal workspace ───────────────────────────── *)

let phase_2_build_workspace () =
  let now = ref 0.0 in
  let next () =
    now := !now +. 1.0;
    !now
  in
  let code_id = Aid.generate () in
  let code_html =
    "<!doctype html><html><body><h1>Hero</h1></body></html>"
  in
  let code : A.code A.t =
    {
      id = code_id;
      kind = A.Code;
      payload = P.Lazy_payload (fun () -> code_html);
      metadata = `Assoc [ ("language", `String "html") ];
      provenance =
        {
          origin_artifact_ids = [];
          created_by = "executor";
          created_at = next ();
        };
    }
  in
  let image_id = Aid.generate () in
  let image : A.image A.t =
    {
      id = image_id;
      kind = A.Image;
      payload = P.Blob_ref "blob://heroes/hero-001.png";
      metadata =
        `Assoc
          [
            ("dimensions", `String "1920x1080");
            ("format", `String "png");
          ];
      provenance =
        {
          origin_artifact_ids = [ code_id ];
          created_by = "executor";
          created_at = next ();
        };
    }
  in
  let ws = W.empty in
  let ws = W.add ws (A.Any code) in
  let ws = W.add ws (A.Any image) in
  (* Provenance DAG edges are explicit; the artifact's
     provenance.origin_artifact_ids is metadata only. *)
  let ws = W.add_edge ws ~from_id:code_id ~to_id:image_id in
  (ws, code_id, image_id)

let test_phase_2_workspace_size () =
  let ws, _code_id, _image_id = phase_2_build_workspace () in
  check_int "workspace size = 2 artifacts" 2 (W.size ws)

let test_phase_2_kind_partition () =
  let ws, _code_id, _image_id = phase_2_build_workspace () in
  let codes = W.list_by_kind_tag ws A.Tag_code in
  let images = W.list_by_kind_tag ws A.Tag_image in
  let audios = W.list_by_kind_tag ws A.Tag_audio in
  let docs = W.list_by_kind_tag ws A.Tag_doc in
  check_int "code count" 1 (List.length codes);
  check_int "image count" 1 (List.length images);
  check_int "audio count" 0 (List.length audios);
  check_int "doc count" 0 (List.length docs)

let test_phase_2_provenance_dag () =
  let ws, code_id, image_id = phase_2_build_workspace () in
  let descendants = W.descendants_of ws code_id in
  check_int "code has 1 descendant" 1 (List.length descendants);
  let desc_strs =
    List.map Shared_types.Artifact_id.to_string descendants
  in
  check_bool "image is a descendant of code"
    (List.mem (Shared_types.Artifact_id.to_string image_id) desc_strs)

(* ── Phase 3: Resilience classifier ──────────────────────────── *)

let test_phase_3_untyped_error_fails_closed () =
  let mode =
    R.classify_string "image generation timed out after 30s"
  in
  match mode with
  | PermanentError { fallback_strategy = HumanHandoff _; _ } ->
      check_bool "untyped timeout → PermanentError/Handoff" true
  | other ->
      let label =
        match other with
        | PermanentError _ -> "Permanent"
        | ResourceExhausted _ -> "ResourceExhausted"
        | AmbiguityError _ -> "Ambiguity"
        | ConsensusError _ -> "Consensus"
        | DegradationRequired _ -> "DegradationRequired"
        | TransientError _ -> "Transient"
      in
      failwith (Printf.sprintf "expected PermanentError/Handoff, got %s" label)

let test_phase_3_default_strategy_handoff () =
  let mode = R.classify_string "connection reset by peer" in
  let strategy = R.default_strategy mode in
  match strategy with
  | R.Handoff _ -> check_bool "untyped error → Handoff" true
  | _ -> failwith "expected Handoff strategy"

(* ── Phase 4: Degradation L2 / L4 ────────────────────────────── *)

let test_phase_4_degradation_l2_yields_tame_strategy () =
  let mode = R.transient ~detail:"image generation timed out" () in
  let strategy = D.apply_level_to_strategy D.L2 mode in
  match strategy with
  | R.Fallback _ ->
      check_bool "L2 transient → Fallback (degraded)" true
  | R.Retry _ ->
      check_bool "L2 transient → Retry (lenient)" true
  | _ -> failwith "L2 unexpected aggressive strategy"

let test_phase_4_degradation_l4_no_retry () =
  let mode = R.classify_string "permanent service deprecated" in
  let strategy = D.apply_level_to_strategy D.L4 mode in
  match strategy with
  | R.Retry _ ->
      failwith "L4 must not retry on permanent failures"
  | R.Abort _ | R.Handoff _ | R.Fallback _ ->
      check_bool "L4 permanent → non-retry strategy" true

(* ── Phase 5: Audit chain integrity ──────────────────────────── *)

let phase_5_build_chain () =
  let phases =
    [
      "autonomous.intent_received";
      "autonomous.phase_intending";
      "multimodal.code_artifact_created";
      "multimodal.image_artifact_created";
      "resilience.untyped_fail_closed";
      "resilience.typed_degradation_l2_applied";
      "resilience.outcome_partial_success";
    ]
  in
  let envelopes_rev =
    List.fold_left
      (fun acc category ->
        let prev_hash =
          match acc with
          | [] -> None
          | last :: _ -> Some (Env.hash_for_chain last)
        in
        let env =
          Env.make ~category ~payload:(`String category) ~prev_hash
        in
        env :: acc)
      [] phases
  in
  (List.rev envelopes_rev, List.length phases)

let test_phase_5_chain_verification () =
  let envelopes, _ = phase_5_build_chain () in
  match S.verify_chain envelopes with
  | Ok () -> check_bool "chain integrity OK" true
  | Error (idx, msg) ->
      failwith
        (Printf.sprintf "chain broken at %d: %s" idx msg)

(* ── Phase 6: Tamper detection ───────────────────────────────── *)

let test_phase_6_tamper_detection () =
  let env1 =
    Env.make ~category:"a" ~payload:(`String "a") ~prev_hash:None
  in
  let env2 =
    Env.make ~category:"b" ~payload:(`String "b")
      ~prev_hash:(Some (Env.hash_for_chain env1))
  in
  let env3_tampered =
    Env.make ~category:"c" ~payload:(`String "c")
      ~prev_hash:(Some "00000000fakehash00000000")
  in
  match S.verify_chain [ env1; env2; env3_tampered ] with
  | Error (_, _) -> check_bool "tamper detected" true
  | Ok () -> failwith "tamper NOT detected"

(* ── Driver ─────────────────────────────────────────────────── *)

let () =
  let cases =
    [
      ("phase_2_workspace_size", test_phase_2_workspace_size);
      ("phase_2_kind_partition", test_phase_2_kind_partition);
      ("phase_2_provenance_dag", test_phase_2_provenance_dag);
      ( "phase_3_untyped_error_fails_closed",
        test_phase_3_untyped_error_fails_closed );
      ( "phase_3_default_strategy_handoff",
        test_phase_3_default_strategy_handoff );
      ( "phase_4_degradation_l2_yields_tame_strategy",
        test_phase_4_degradation_l2_yields_tame_strategy );
      ( "phase_4_degradation_l4_no_retry",
        test_phase_4_degradation_l4_no_retry );
      ("phase_5_chain_verification", test_phase_5_chain_verification);
      ("phase_6_tamper_detection", test_phase_6_tamper_detection);
    ]
  in
  List.iter
    (fun (name, f) ->
      try f ()
      with e ->
        Printf.printf "FAIL %s: %s\n" name (Printexc.to_string e);
        exit 1)
    cases;
  Printf.printf
    "test_multimodal_resilience_audit_composition: %d checks passed\n"
    (List.length cases)
