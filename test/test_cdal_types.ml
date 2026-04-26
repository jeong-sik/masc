(** test_cdal_types -- Unit tests for Cdal_types module.

    Verifies JSON roundtrip, judgment hash determinism,
    and canonical JSON key ordering. *)

module CT = Masc_mcp.Cdal_types

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let make_finding
      ?(check_id = "chk-001")
      ?(event_id = Some "evt-001")
      ?(observed = `String "draft")
      ?(expected = `String "execute")
      ?(trace_ref = Some "proof-store://run-1/trace-001")
      ()
  : CT.contract_finding
  =
  { check_id; event_id; observed; expected; trace_ref }
;;

let make_gap
      ?(artifact = "contract.json")
      ?(reason = "missing field")
      ?(impact = CT.Annotation_only)
      ()
  : CT.completeness_gap
  =
  { artifact; reason; impact }
;;

let make_check_result
      ?(check_id = "mode_escalation")
      ?(status = CT.Satisfied)
      ?(findings = [])
      ?(completeness_gaps = [])
      ()
  : CT.check_result
  =
  { check_id; status; findings; completeness_gaps }
;;

let make_verdict
      ?(run_id = "test-run-001")
      ?(contract_id = "md5:abc123")
      ?(claim_scope = CT.claim_scope_phase1)
      ?(judgment_basis_hash = "md5:basis-hash")
      ?(judgment_hash = "")
      ?(loader_semantics_version = CT.loader_semantics_version_phase1)
      ?(schema_compat_mode = CT.schema_compat_mode_v1)
      ?(status = CT.Satisfied)
      ?(findings = [])
      ?(completeness_gaps = [])
      ?(check_results = [])
      ()
  : CT.contract_verdict
  =
  { run_id
  ; contract_id
  ; claim_scope
  ; judgment_basis_hash
  ; judgment_hash
  ; loader_semantics_version
  ; schema_compat_mode
  ; status
  ; findings
  ; completeness_gaps
  ; check_results
  }
;;

(* ================================================================ *)
(* contract_finding roundtrip                                        *)
(* ================================================================ *)

let test_finding_json_roundtrip () =
  let f = make_finding () in
  let json = CT.contract_finding_to_json f in
  match CT.contract_finding_of_json json with
  | Ok f2 ->
    Alcotest.(check string) "check_id" f.check_id f2.check_id;
    Alcotest.(check (option string)) "event_id" f.event_id f2.event_id;
    Alcotest.(check (option string)) "trace_ref" f.trace_ref f2.trace_ref;
    Alcotest.(check string)
      "observed"
      (Yojson.Safe.to_string f.observed)
      (Yojson.Safe.to_string f2.observed);
    Alcotest.(check string)
      "expected"
      (Yojson.Safe.to_string f.expected)
      (Yojson.Safe.to_string f2.expected)
  | Error e -> Alcotest.fail e
;;

let test_finding_none_fields () =
  let f = make_finding ~event_id:None ~trace_ref:None () in
  let json = CT.contract_finding_to_json f in
  match CT.contract_finding_of_json json with
  | Ok f2 ->
    Alcotest.(check (option string)) "event_id None" None f2.event_id;
    Alcotest.(check (option string)) "trace_ref None" None f2.trace_ref
  | Error e -> Alcotest.fail e
;;

(* ================================================================ *)
(* completeness_gap roundtrip                                        *)
(* ================================================================ *)

let test_gap_json_roundtrip () =
  let g = make_gap () in
  let json = CT.completeness_gap_to_json g in
  match CT.completeness_gap_of_json json with
  | Ok g2 ->
    Alcotest.(check string) "artifact" g.artifact g2.artifact;
    Alcotest.(check string) "reason" g.reason g2.reason;
    Alcotest.(check string)
      "impact"
      (CT.completeness_impact_to_string g.impact)
      (CT.completeness_impact_to_string g2.impact)
  | Error e -> Alcotest.fail e
;;

let test_gap_blocks_verdict () =
  let g = make_gap ~impact:Blocks_verdict () in
  let json = CT.completeness_gap_to_json g in
  match CT.completeness_gap_of_json json with
  | Ok g2 ->
    Alcotest.(check string)
      "impact"
      "blocks_verdict"
      (CT.completeness_impact_to_string g2.impact)
  | Error e -> Alcotest.fail e
;;

(* ================================================================ *)
(* check_result roundtrip                                            *)
(* ================================================================ *)

let test_check_result_json_roundtrip () =
  let f = make_finding () in
  let g = make_gap ~impact:Blocks_verdict () in
  let cr =
    make_check_result ~status:Violated ~findings:[ f ] ~completeness_gaps:[ g ] ()
  in
  let json = CT.check_result_to_json cr in
  match CT.check_result_of_json json with
  | Ok cr2 ->
    Alcotest.(check string) "check_id" cr.check_id cr2.check_id;
    Alcotest.(check string) "status" "violated" (CT.contract_status_to_string cr2.status);
    Alcotest.(check int) "findings count" 1 (List.length cr2.findings);
    Alcotest.(check int) "gaps count" 1 (List.length cr2.completeness_gaps)
  | Error e -> Alcotest.fail e
;;

(* ================================================================ *)
(* contract_verdict roundtrip                                        *)
(* ================================================================ *)

let test_verdict_json_roundtrip () =
  let f = make_finding () in
  let g = make_gap () in
  let cr = make_check_result ~findings:[ f ] ~completeness_gaps:[ g ] () in
  let v =
    make_verdict ~findings:[ f ] ~completeness_gaps:[ g ] ~check_results:[ cr ] ()
  in
  let json = CT.contract_verdict_to_json v in
  match CT.contract_verdict_of_json json with
  | Ok v2 ->
    Alcotest.(check string) "run_id" v.run_id v2.run_id;
    Alcotest.(check string) "contract_id" v.contract_id v2.contract_id;
    Alcotest.(check string) "claim_scope" v.claim_scope v2.claim_scope;
    Alcotest.(check string) "basis_hash" v.judgment_basis_hash v2.judgment_basis_hash;
    Alcotest.(check string) "judgment_hash" v.judgment_hash v2.judgment_hash;
    Alcotest.(check string)
      "loader_semantics_version"
      v.loader_semantics_version
      v2.loader_semantics_version;
    Alcotest.(check string)
      "schema_compat_mode"
      v.schema_compat_mode
      v2.schema_compat_mode;
    Alcotest.(check string)
      "status"
      (CT.contract_status_to_string v.status)
      (CT.contract_status_to_string v2.status);
    Alcotest.(check int) "findings" 1 (List.length v2.findings);
    Alcotest.(check int) "gaps" 1 (List.length v2.completeness_gaps);
    Alcotest.(check int) "check_results" 1 (List.length v2.check_results)
  | Error e -> Alcotest.fail e
;;

(* ================================================================ *)
(* judgment hash                                                     *)
(* ================================================================ *)

let test_judgment_hash_determinism () =
  let v = make_verdict () in
  let h1 = CT.compute_judgment_hash v in
  let h2 = CT.compute_judgment_hash v in
  Alcotest.(check string) "same hash" h1 h2;
  (* Verify it starts with md5: prefix *)
  Alcotest.(check bool)
    "md5 prefix"
    true
    (String.length h1 > 4 && String.sub h1 0 4 = "md5:")
;;

let test_judgment_hash_changes_with_content () =
  let v1 = make_verdict ~status:Satisfied () in
  let v2 = make_verdict ~status:Violated () in
  let h1 = CT.compute_judgment_hash v1 in
  let h2 = CT.compute_judgment_hash v2 in
  Alcotest.(check bool) "different hash for different status" true (h1 <> h2)
;;

let test_judgment_hash_ignores_existing_hash () =
  let v1 = make_verdict ~judgment_hash:"old-hash-1" () in
  let v2 = make_verdict ~judgment_hash:"old-hash-2" () in
  let h1 = CT.compute_judgment_hash v1 in
  let h2 = CT.compute_judgment_hash v2 in
  Alcotest.(check string) "existing hash ignored" h1 h2
;;

(* ================================================================ *)
(* canonical JSON sorted keys                                        *)
(* ================================================================ *)

let extract_keys = function
  | `Assoc fields -> List.map fst fields
  | _ -> []
;;

let test_canonical_json_sorted () =
  let v = make_verdict () in
  let json = CT.contract_verdict_to_json v in
  let keys = extract_keys json in
  let sorted = List.sort String.compare keys in
  Alcotest.(check (list string)) "top-level keys sorted" sorted keys
;;

let test_finding_keys_sorted () =
  let f = make_finding () in
  let json = CT.contract_finding_to_json f in
  let keys = extract_keys json in
  let sorted = List.sort String.compare keys in
  Alcotest.(check (list string)) "finding keys sorted" sorted keys
;;

let test_gap_keys_sorted () =
  let g = make_gap () in
  let json = CT.completeness_gap_to_json g in
  let keys = extract_keys json in
  let sorted = List.sort String.compare keys in
  Alcotest.(check (list string)) "gap keys sorted" sorted keys
;;

(* ================================================================ *)
(* String conversion helpers                                         *)
(* ================================================================ *)

let test_contract_status_roundtrip () =
  let statuses = [ CT.Satisfied; Violated; Inconclusive ] in
  List.iter
    (fun s ->
       let str = CT.contract_status_to_string s in
       match CT.contract_status_of_string str with
       | Ok s2 ->
         Alcotest.(check string)
           "status roundtrip"
           (CT.contract_status_to_string s)
           (CT.contract_status_to_string s2)
       | Error e -> Alcotest.fail e)
    statuses
;;

let test_completeness_impact_roundtrip () =
  let impacts = [ CT.Blocks_verdict; Annotation_only ] in
  List.iter
    (fun i ->
       let str = CT.completeness_impact_to_string i in
       match CT.completeness_impact_of_string str with
       | Ok i2 ->
         Alcotest.(check string)
           "impact roundtrip"
           (CT.completeness_impact_to_string i)
           (CT.completeness_impact_to_string i2)
       | Error e -> Alcotest.fail e)
    impacts
;;

let test_invalid_status_string () =
  match CT.contract_status_of_string "bogus" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for invalid status"
;;

let test_invalid_impact_string () =
  match CT.completeness_impact_of_string "bogus" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for invalid impact"
;;

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run
    "Cdal_types"
    [ ( "finding"
      , [ Alcotest.test_case "json roundtrip" `Quick test_finding_json_roundtrip
        ; Alcotest.test_case "none fields" `Quick test_finding_none_fields
        ; Alcotest.test_case "keys sorted" `Quick test_finding_keys_sorted
        ] )
    ; ( "completeness_gap"
      , [ Alcotest.test_case "json roundtrip" `Quick test_gap_json_roundtrip
        ; Alcotest.test_case "blocks_verdict" `Quick test_gap_blocks_verdict
        ; Alcotest.test_case "keys sorted" `Quick test_gap_keys_sorted
        ] )
    ; ( "check_result"
      , [ Alcotest.test_case "json roundtrip" `Quick test_check_result_json_roundtrip ] )
    ; ( "contract_verdict"
      , [ Alcotest.test_case "json roundtrip" `Quick test_verdict_json_roundtrip
        ; Alcotest.test_case "canonical json sorted" `Quick test_canonical_json_sorted
        ] )
    ; ( "judgment_hash"
      , [ Alcotest.test_case "determinism" `Quick test_judgment_hash_determinism
        ; Alcotest.test_case
            "changes with content"
            `Quick
            test_judgment_hash_changes_with_content
        ; Alcotest.test_case
            "ignores existing hash"
            `Quick
            test_judgment_hash_ignores_existing_hash
        ] )
    ; ( "string_conversions"
      , [ Alcotest.test_case
            "contract_status roundtrip"
            `Quick
            test_contract_status_roundtrip
        ; Alcotest.test_case
            "completeness_impact roundtrip"
            `Quick
            test_completeness_impact_roundtrip
        ; Alcotest.test_case "invalid status" `Quick test_invalid_status_string
        ; Alcotest.test_case "invalid impact" `Quick test_invalid_impact_string
        ] )
    ]
;;
