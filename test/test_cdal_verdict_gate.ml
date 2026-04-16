(** test_cdal_verdict_gate -- Unit tests for CDAL verdict gate logic.

    Tests the deterministic gate that blocks task completion
    based on CDAL verdict status. *)

module CVG = Masc_mcp.Cdal_verdict_gate
module CT = Masc_mcp.Cdal_types

let make_verdict
    ?(run_id = "test-run-001")
    ?(contract_id = "md5:test-contract")
    ?(status = CT.Satisfied)
    ?(findings = [])
    ?(gaps = [])
    () : CT.contract_verdict =
  let basis_input =
    Printf.sprintf "%s|%s|%s"
      contract_id
      CT.loader_semantics_version_phase1
      CT.schema_compat_mode_v1 in
  let basis_hash =
    "md5:" ^ (Digest.string basis_input |> Digest.to_hex) in
  let v_no_hash : CT.contract_verdict = {
    run_id;
    contract_id;
    claim_scope = CT.claim_scope_phase1;
    judgment_basis_hash = basis_hash;
    judgment_hash = "";
    loader_semantics_version = CT.loader_semantics_version_phase1;
    schema_compat_mode = CT.schema_compat_mode_v1;
    status;
    findings;
    completeness_gaps = gaps;
    check_results = [];
  } in
  let judgment_hash = CT.compute_judgment_hash v_no_hash in
  { v_no_hash with judgment_hash }

let make_finding
    ?(check_id = "test_check")
    ?(observed = `String "bad")
    ?(expected = `String "good")
    () : CT.contract_finding =
  { check_id; event_id = None; observed; expected; trace_ref = None }

let make_gap
    ?(artifact = "test.json")
    ?(reason = "missing")
    ?(impact = CT.Blocks_verdict)
    () : CT.completeness_gap =
  { artifact; reason; impact }

(* ================================================================ *)
(* check_verdict tests                                               *)
(* ================================================================ *)

let test_satisfied_allows () =
  let v = make_verdict ~status:CT.Satisfied () in
  match CVG.check_verdict v with
  | CVG.Allow -> ()
  | CVG.Reject msg ->
    Alcotest.fail (Printf.sprintf "Satisfied should Allow, got Reject: %s" msg)

let test_violated_rejects () =
  let finding = make_finding ~check_id:"execution_mode" () in
  let v = make_verdict ~status:CT.Violated ~findings:[finding] () in
  match CVG.check_verdict v with
  | CVG.Reject msg ->
    Alcotest.(check bool) "contains check_id" true
      (Astring.String.is_infix ~affix:"execution_mode" msg);
    Alcotest.(check bool) "contains Violated" true
      (Astring.String.is_infix ~affix:"Violated" msg)
  | CVG.Allow ->
    Alcotest.fail "Violated should Reject"

let test_violated_no_findings_still_rejects () =
  let v = make_verdict ~status:CT.Violated () in
  match CVG.check_verdict v with
  | CVG.Reject _ -> ()
  | CVG.Allow ->
    Alcotest.fail "Violated with no findings should still Reject"

let test_inconclusive_blocking_gap_rejects () =
  let gap = make_gap ~artifact:"evidence.json" ~impact:CT.Blocks_verdict () in
  let v = make_verdict ~status:CT.Inconclusive ~gaps:[gap] () in
  match CVG.check_verdict v with
  | CVG.Reject msg ->
    Alcotest.(check bool) "contains artifact" true
      (Astring.String.is_infix ~affix:"evidence.json" msg)
  | CVG.Allow ->
    Alcotest.fail "Inconclusive with blocking gap should Reject"

let test_inconclusive_annotation_only_allows () =
  let gap = make_gap ~impact:CT.Annotation_only () in
  let v = make_verdict ~status:CT.Inconclusive ~gaps:[gap] () in
  match CVG.check_verdict v with
  | CVG.Allow -> ()
  | CVG.Reject msg ->
    Alcotest.fail (Printf.sprintf "Annotation_only gap should Allow, got: %s" msg)

let test_inconclusive_no_gaps_allows () =
  let v = make_verdict ~status:CT.Inconclusive () in
  match CVG.check_verdict v with
  | CVG.Allow -> ()
  | CVG.Reject msg ->
    Alcotest.fail (Printf.sprintf "Inconclusive with no gaps should Allow, got: %s" msg)

let test_inconclusive_mixed_gaps_rejects () =
  let blocking = make_gap ~artifact:"a.json" ~impact:CT.Blocks_verdict () in
  let annotation = make_gap ~artifact:"b.json" ~impact:CT.Annotation_only () in
  let v = make_verdict ~status:CT.Inconclusive ~gaps:[blocking; annotation] () in
  match CVG.check_verdict v with
  | CVG.Reject _ -> ()
  | CVG.Allow ->
    Alcotest.fail "Mixed gaps with at least one blocking should Reject"

(* ================================================================ *)
(* gate_check with persistence (integration)                         *)
(* ================================================================ *)

let with_temp_dir f =
  let dir = Filename.temp_dir "cdal_gate_test" "" in
  Fun.protect ~finally:(fun () ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))
  ) (fun () -> f dir)

let write_verdict_jsonl ~base_dir ?task_id (verdict : CT.contract_verdict) =
  let today = Unix.gmtime (Unix.gettimeofday ()) in
  let date_dir = Printf.sprintf "%04d-%02d"
    (today.tm_year + 1900) (today.tm_mon + 1) in
  let dir = Filename.concat base_dir date_dir in
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote dir)));
  let day_file = Printf.sprintf "%02d.jsonl" today.tm_mday in
  let path = Filename.concat dir day_file in
  let json = CT.contract_verdict_to_json verdict in
  let envelope = match task_id with
    | None -> json
    | Some tid ->
      match json with
      | `Assoc fields -> `Assoc (("_task_id", `String tid) :: fields)
      | other -> other
  in
  let oc = open_out_gen [Open_append; Open_creat] 0o644 path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc (Yojson.Safe.to_string envelope);
    output_char oc '\n')

let test_gate_no_verdict_rejects () =
  with_temp_dir (fun base_dir ->
    match CVG.gate_check ~base_dir ~task_id:"task-missing" () with
    | Some msg ->
      Alcotest.(check bool) "mentions task id" true
        (Astring.String.is_infix ~affix:"task-missing" msg)
    | None ->
      Alcotest.fail "No verdict should reject")

let test_gate_satisfied_verdict_allows () =
  with_temp_dir (fun base_dir ->
    let verdict = make_verdict ~status:CT.Satisfied () in
    write_verdict_jsonl ~base_dir ~task_id:"task-001" verdict;
    match CVG.gate_check ~base_dir ~task_id:"task-001" () with
    | None -> ()
    | Some msg ->
      Alcotest.fail (Printf.sprintf "Satisfied verdict should allow, got: %s" msg))

let test_gate_violated_verdict_rejects () =
  with_temp_dir (fun base_dir ->
    let finding = make_finding () in
    let verdict = make_verdict ~status:CT.Violated ~findings:[finding] () in
    write_verdict_jsonl ~base_dir ~task_id:"task-002" verdict;
    match CVG.gate_check ~base_dir ~task_id:"task-002" () with
    | Some _ -> ()
    | None ->
      Alcotest.fail "Violated verdict should reject")

let test_gate_different_task_id_not_found () =
  with_temp_dir (fun base_dir ->
    let verdict = make_verdict ~status:CT.Satisfied () in
    write_verdict_jsonl ~base_dir ~task_id:"task-other" verdict;
    match CVG.gate_check ~base_dir ~task_id:"task-mine" () with
    | Some _ -> ()
    | None ->
      Alcotest.fail "Different task_id should not match")

let test_gate_latest_verdict_wins () =
  with_temp_dir (fun base_dir ->
    let v1 = make_verdict ~run_id:"run-old" ~status:CT.Violated () in
    write_verdict_jsonl ~base_dir ~task_id:"task-003" v1;
    let v2 = make_verdict ~run_id:"run-new" ~status:CT.Satisfied () in
    write_verdict_jsonl ~base_dir ~task_id:"task-003" v2;
    match CVG.gate_check ~base_dir ~task_id:"task-003" () with
    | None -> ()
    | Some msg ->
      Alcotest.fail (Printf.sprintf "Latest Satisfied should allow, got: %s" msg))

(* ================================================================ *)
(* Test suite                                                        *)
(* ================================================================ *)

let () =
  Alcotest.run "cdal_verdict_gate" [
    ("check_verdict", [
      Alcotest.test_case "satisfied allows" `Quick test_satisfied_allows;
      Alcotest.test_case "violated rejects" `Quick test_violated_rejects;
      Alcotest.test_case "violated no findings rejects" `Quick test_violated_no_findings_still_rejects;
      Alcotest.test_case "inconclusive blocking gap rejects" `Quick test_inconclusive_blocking_gap_rejects;
      Alcotest.test_case "inconclusive annotation only allows" `Quick test_inconclusive_annotation_only_allows;
      Alcotest.test_case "inconclusive no gaps allows" `Quick test_inconclusive_no_gaps_allows;
      Alcotest.test_case "inconclusive mixed gaps rejects" `Quick test_inconclusive_mixed_gaps_rejects;
    ]);
    ("gate_check_integration", [
      Alcotest.test_case "no verdict rejects" `Quick test_gate_no_verdict_rejects;
      Alcotest.test_case "satisfied verdict allows" `Quick test_gate_satisfied_verdict_allows;
      Alcotest.test_case "violated verdict rejects" `Quick test_gate_violated_verdict_rejects;
      Alcotest.test_case "different task_id not found" `Quick test_gate_different_task_id_not_found;
      Alcotest.test_case "latest verdict wins" `Quick test_gate_latest_verdict_wins;
    ]);
  ]
