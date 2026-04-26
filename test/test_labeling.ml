open Alcotest
module CT = Masc_mcp.Cdal_types
module L = Masc_mcp.Labeling

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let check_float msg expected actual =
  let epsilon = 0.001 in
  if Float.abs (expected -. actual) > epsilon
  then fail (Printf.sprintf "%s: expected %.4f, got %.4f" msg expected actual)
;;

let dummy_verdict ?(status = CT.Satisfied) () : CT.contract_verdict =
  { run_id = "test-run-1"
  ; contract_id = "test-contract-1"
  ; claim_scope = CT.claim_scope_phase1
  ; judgment_basis_hash = "basis-hash"
  ; judgment_hash = "judgment-hash"
  ; loader_semantics_version = CT.loader_semantics_version_phase1
  ; schema_compat_mode = CT.schema_compat_mode_v1
  ; status
  ; findings = []
  ; completeness_gaps = []
  ; check_results = []
  }
;;

let make_lv label : L.labeled_verdict =
  { verdict = dummy_verdict ()
  ; label
  ; labeler = "human:test"
  ; note = None
  ; labeled_at = "2026-03-29T00:00:00Z"
  }
;;

(* ================================================================ *)
(* label string round-trip                                           *)
(* ================================================================ *)

let test_label_roundtrip () =
  let labels = [ L.Supported; L.Unsupported; L.Ambiguous; L.Drift ] in
  List.iter
    (fun l ->
       let s = L.label_to_string l in
       match L.label_of_string s with
       | Ok l' -> check string "round-trip" (L.label_to_string l) (L.label_to_string l')
       | Error e -> fail (Printf.sprintf "label_of_string failed: %s" e))
    labels
;;

let test_label_of_string_invalid () =
  match L.label_of_string "garbage" with
  | Error _ -> ()
  | Ok _ -> fail "expected error for invalid label"
;;

(* ================================================================ *)
(* confusion summary                                                 *)
(* ================================================================ *)

let test_compute_confusion () =
  let verdicts =
    List.map
      make_lv
      [ L.Supported
      ; L.Supported
      ; L.Supported
      ; L.Unsupported
      ; L.Unsupported
      ; L.Ambiguous
      ; L.Drift
      ]
  in
  let c = L.compute_confusion verdicts in
  check int "supported" 3 c.supported;
  check int "unsupported" 2 c.unsupported;
  check int "ambiguous" 1 c.ambiguous;
  check int "drift" 1 c.drift
;;

let test_compute_confusion_empty () =
  let c = L.compute_confusion [] in
  check int "supported" 0 c.supported;
  check int "unsupported" 0 c.unsupported;
  check int "ambiguous" 0 c.ambiguous;
  check int "drift" 0 c.drift
;;

(* ================================================================ *)
(* precision metrics                                                 *)
(* ================================================================ *)

let test_precision_strict () =
  (* 15 / (15 + 3 + 2) = 0.75 *)
  let c : L.confusion_summary =
    { supported = 15; unsupported = 3; ambiguous = 2; drift = 1 }
  in
  check_float "precision_strict" 0.75 (L.compute_precision_strict c)
;;

let test_precision_lenient () =
  (* 15 / (15 + 3) = 0.8333... *)
  let c : L.confusion_summary =
    { supported = 15; unsupported = 3; ambiguous = 2; drift = 1 }
  in
  check_float "precision_lenient" 0.8333 (L.compute_precision_lenient c)
;;

let test_precision_zero_denom () =
  let c : L.confusion_summary =
    { supported = 0; unsupported = 0; ambiguous = 0; drift = 5 }
  in
  check_float "strict zero" 0.0 (L.compute_precision_strict c);
  check_float "lenient zero" 0.0 (L.compute_precision_lenient c)
;;

(* ================================================================ *)
(* claim coverage                                                    *)
(* ================================================================ *)

let test_claim_coverage () =
  check_float "normal" 0.8 (L.compute_claim_coverage ~labeled:16 ~total:20);
  check_float "full" 1.0 (L.compute_claim_coverage ~labeled:20 ~total:20);
  check_float "zero total" 0.0 (L.compute_claim_coverage ~labeled:0 ~total:0)
;;

(* ================================================================ *)
(* build_output_contract                                             *)
(* ================================================================ *)

let test_build_output_contract () =
  let verdicts =
    List.map make_lv [ L.Supported; L.Supported; L.Supported; L.Unsupported; L.Ambiguous ]
  in
  let oc =
    L.build_output_contract
      ~workload_name:"coding_task"
      ~protocol_version:"v0.1"
      ~judge_protocol_version:"v0"
      ~label_owner:"alice"
      ~metric_owner:"bob"
      ~total_claims:10
      ~drift_note:""
      verdicts
  in
  check string "workload" "coding_task" oc.workload_name;
  check string "protocol_version" "v0.1" oc.protocol_version;
  check int "confusion.supported" 3 oc.confusion.supported;
  check int "confusion.unsupported" 1 oc.confusion.unsupported;
  check int "confusion.ambiguous" 1 oc.confusion.ambiguous;
  (* precision_strict = 3 / (3 + 1 + 1) = 0.6 *)
  check_float "precision_strict" 0.6 oc.precision_strict;
  (* precision_lenient = 3 / (3 + 1) = 0.75 *)
  check_float "precision_lenient" 0.75 oc.precision_lenient;
  (* claim_coverage = 5 / 10 = 0.5 (5 non-drift labeled out of 10 total) *)
  check_float "claim_coverage" 0.5 oc.claim_coverage
;;

(* ================================================================ *)
(* JSON round-trip                                                   *)
(* ================================================================ *)

let test_labeled_verdict_json_roundtrip () =
  let lv : L.labeled_verdict =
    { verdict = dummy_verdict ()
    ; label = L.Supported
    ; labeler = "human:alice"
    ; note = Some "looks correct"
    ; labeled_at = "2026-03-29T12:00:00Z"
    }
  in
  let json = L.labeled_verdict_to_json lv in
  match L.labeled_verdict_of_json json with
  | Error e -> fail (Printf.sprintf "JSON round-trip failed: %s" e)
  | Ok lv' ->
    check string "label" "supported" (L.label_to_string lv'.label);
    check string "labeler" "human:alice" lv'.labeler;
    check string "note" "looks correct" (Option.value ~default:"NONE" lv'.note);
    check string "labeled_at" "2026-03-29T12:00:00Z" lv'.labeled_at;
    check string "run_id" "test-run-1" lv'.verdict.run_id
;;

let test_output_contract_json () =
  let oc : L.output_contract =
    { workload_name = "coding_task"
    ; protocol_version = "v0.1"
    ; judge_protocol_version = "v0"
    ; label_owner = "alice"
    ; metric_owner = "bob"
    ; confusion = { supported = 10; unsupported = 2; ambiguous = 1; drift = 0 }
    ; claim_coverage = 0.9
    ; precision_strict = 0.769
    ; precision_lenient = 0.833
    ; drift_note = ""
    }
  in
  let json = L.output_contract_to_json oc in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "workload_name" fields with
     | Some (`String "coding_task") -> ()
     | _ -> fail "missing workload_name");
    (match List.assoc_opt "protocol_version" fields with
     | Some (`String "v0.1") -> ()
     | _ -> fail "missing or wrong protocol_version");
    (match List.assoc_opt "precision_strict" fields with
     | Some (`Float _) -> ()
     | _ -> fail "missing precision_strict")
  | _ -> fail "expected JSON object"
;;

(* ================================================================ *)
(* Test runner                                                       *)
(* ================================================================ *)

let () =
  run
    "Labeling"
    [ ( "label"
      , [ test_case "roundtrip" `Quick test_label_roundtrip
        ; test_case "invalid" `Quick test_label_of_string_invalid
        ] )
    ; ( "confusion"
      , [ test_case "counts" `Quick test_compute_confusion
        ; test_case "empty" `Quick test_compute_confusion_empty
        ] )
    ; ( "precision"
      , [ test_case "strict" `Quick test_precision_strict
        ; test_case "lenient" `Quick test_precision_lenient
        ; test_case "zero denom" `Quick test_precision_zero_denom
        ] )
    ; "coverage", [ test_case "claim coverage" `Quick test_claim_coverage ]
    ; "contract", [ test_case "build" `Quick test_build_output_contract ]
    ; ( "json"
      , [ test_case "labeled verdict roundtrip" `Quick test_labeled_verdict_json_roundtrip
        ; test_case "output contract" `Quick test_output_contract_json
        ] )
    ]
;;
