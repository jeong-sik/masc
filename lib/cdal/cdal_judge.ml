(** Cdal_judge -- Phase 1A contract judge with 5 active checks.

    @since CDAL Phase 1A *)

(* ================================================================ *)
(* Check 1: Execution mode                                          *)
(* ================================================================ *)

let check_execution_mode (b : Cdal_loader.loaded_bundle) : Cdal_types.check_result =
  let check_id = "runtime.requested_execution_mode" in
  let proof = b.proof in
  let contract_mode = b.contract.runtime_constraints.requested_execution_mode in
  let proof_requested = proof.requested_execution_mode in
  let proof_effective = proof.effective_execution_mode in
  (* Propagation: proof.requested must match contract.runtime_constraints.requested *)
  let propagation_ok =
    Masc_mcp_cdal_runtime.Execution_mode.equal proof_requested contract_mode
  in
  (* No-upward-escalation: effective <= requested *)
  let escalation_ok =
    Masc_mcp_cdal_runtime.Execution_mode.can_serve
      ~requested:proof_requested
      ~effective:proof_effective
  in
  if propagation_ok && escalation_ok
  then { check_id; status = Satisfied; findings = []; completeness_gaps = [] }
  else
    let propagation_finding : Cdal_types.contract_finding option =
      if propagation_ok
      then None
      else
        Some
          { Cdal_types.check_id
          ; event_id = None
          ; observed =
              `String (Masc_mcp_cdal_runtime.Execution_mode.to_string proof_requested)
          ; expected =
              `String (Masc_mcp_cdal_runtime.Execution_mode.to_string contract_mode)
          ; trace_ref = None
          }
    in
    let escalation_finding : Cdal_types.contract_finding option =
      if escalation_ok
      then None
      else
        Some
          { Cdal_types.check_id
          ; event_id = Some "escalation"
          ; observed =
              `String (Masc_mcp_cdal_runtime.Execution_mode.to_string proof_effective)
          ; expected =
              `String
                (Printf.sprintf
                   "<= %s"
                   (Masc_mcp_cdal_runtime.Execution_mode.to_string proof_requested))
          ; trace_ref = None
          }
    in
    { check_id
    ; status = Violated
    ; findings = List.filter_map Fun.id [propagation_finding; escalation_finding]
    ; completeness_gaps = []
    }
;;

(* ================================================================ *)
(* Check 2: Risk class                                              *)
(* ================================================================ *)

let check_risk_class (b : Cdal_loader.loaded_bundle) : Cdal_types.check_result =
  let check_id = "runtime.risk_class" in
  let contract_risk = b.contract.runtime_constraints.risk_class in
  let proof_risk = b.proof.risk_class in
  if Masc_mcp_cdal_runtime.Risk_class.equal contract_risk proof_risk
  then { check_id; status = Satisfied; findings = []; completeness_gaps = [] }
  else
    { check_id
    ; status = Violated
    ; findings =
        [ { check_id
          ; event_id = None
          ; observed = `String (Masc_mcp_cdal_runtime.Risk_class.to_string proof_risk)
          ; expected = `String (Masc_mcp_cdal_runtime.Risk_class.to_string contract_risk)
          ; trace_ref = None
          }
        ]
    ; completeness_gaps = []
    }
;;

(* ================================================================ *)
(* Check 3: Contract snapshot                                       *)
(* ================================================================ *)

let check_contract_snapshot (b : Cdal_loader.loaded_bundle) : Cdal_types.check_result =
  let check_id = "proof.contract_snapshot" in
  let proof_contract_id = b.proof.contract_id in
  let recomputed = b.recomputed_contract_id in
  if String.equal proof_contract_id recomputed
  then { check_id; status = Satisfied; findings = []; completeness_gaps = [] }
  else
    { check_id
    ; status = Violated
    ; findings =
        [ { check_id
          ; event_id = None
          ; observed = `String proof_contract_id
          ; expected = `String recomputed
          ; trace_ref = None
          }
        ]
    ; completeness_gaps = []
    }
;;

(* ================================================================ *)
(* Check 4: Required artifact                                       *)
(* ================================================================ *)

let check_required_artifact (_b : Cdal_loader.loaded_bundle) : Cdal_types.check_result =
  (* The loader already verified manifest.json and contract.json exist
     and are parseable. If the loader succeeded, this check is Satisfied. *)
  { check_id = "proof.required_artifact"
  ; status = Satisfied
  ; findings = []
  ; completeness_gaps = []
  }
;;

(* ================================================================ *)
(* Check 5: Review requirement                                      *)
(* ================================================================ *)

let review_warning_artifact = "evidence/review_warning.json"

let has_review_warning_ref (proof : Masc_mcp_cdal_runtime.Cdal_proof.t) : bool =
  List.exists
    (fun ref_ -> String.ends_with ~suffix:review_warning_artifact ref_)
    proof.raw_evidence_refs
;;

let check_review_requirement (b : Cdal_loader.loaded_bundle) : Cdal_types.check_result =
  let check_id = "runtime.review_requirement" in
  match b.contract.runtime_constraints.review_requirement with
  | None -> { check_id; status = Satisfied; findings = []; completeness_gaps = [] }
  | Some _ ->
    let reason =
      if has_review_warning_ref b.proof
      then
        "review_requirement present, but OAS only captured warning-style review \
         evidence; use verification FSM for explicit approval"
      else
        "review_requirement present, but no review evidence artifact was captured; use \
         verification FSM for explicit approval"
    in
    { check_id
    ; status = Inconclusive
    ; findings = []
    ; completeness_gaps =
        [ { Cdal_types.artifact = review_warning_artifact
          ; reason
          ; impact = Blocks_verdict
          }
        ]
    }
;;

(* ================================================================ *)
(* Check 6: Runtime terminal status (completion precondition)       *)
(* ================================================================ *)

(* A run can only verify-complete its task/goal if it actually reached a
   [Completed] terminal state. Before this check, judge ran only the four
   containment checks plus review-requirement, so a [Cancelled]/[Timed_out]/
   [Errored]/[Context_overflow] run could be judged [Satisfied] as long as
   the containment checks passed — i.e. an unfinished run could verify task
   completion. This stays within the [phase1_scoped_runtime_audit] scope:
   it audits the proof's terminal [result_status], not deliverable
   correctness (the typed evidence evaluator's job, out of Phase 1A scope). *)
let check_result_status (b : Cdal_loader.loaded_bundle) : Cdal_types.check_result =
  let check_id = "runtime.result_status" in
  let module P = Masc_mcp_cdal_runtime.Cdal_proof in
  match b.proof.result_status with
  | P.Completed -> { check_id; status = Satisfied; findings = []; completeness_gaps = [] }
  | P.Errored ->
    (* Explicit runtime failure (hook/verifier crash, unexpected error):
       the run did not complete successfully. *)
    { check_id
    ; status = Violated
    ; findings =
        [ { Cdal_types.check_id
          ; event_id = None
          ; observed = `String (P.result_status_to_string b.proof.result_status)
          ; expected = `String (P.result_status_to_string P.Completed)
          ; trace_ref = None
          }
        ]
    ; completeness_gaps = []
    }
  | (P.Timed_out | P.Cancelled | P.Context_overflow) as status ->
    (* Cut short before a completed terminal state (limit exceeded, policy
       gate stop, or context exhaustion). Completion cannot be confirmed, so
       the verdict is withheld ([Inconclusive] with a blocking gap) rather
       than falsely [Satisfied] or falsely [Violated]. *)
    { check_id
    ; status = Inconclusive
    ; findings = []
    ; completeness_gaps =
        [ { Cdal_types.artifact = "proof/status.json"
          ; reason =
              Printf.sprintf
                "run terminated as %s, not completed; completion cannot be verified \
                 from an unfinished run"
                (P.result_status_to_string status)
          ; impact = Blocks_verdict
          }
        ]
    }
;;

(* ================================================================ *)
(* Verdict derivation                                               *)
(* ================================================================ *)

let derive_status (checks : Cdal_types.check_result list) : Cdal_types.contract_status =
  let has_violated =
    List.exists (fun (c : Cdal_types.check_result) -> c.status = Violated) checks
  in
  if has_violated
  then Violated
  else (
    let has_blocking_inconclusive =
      List.exists
        (fun (c : Cdal_types.check_result) ->
           c.status = Inconclusive
           && List.exists
                (fun (g : Cdal_types.completeness_gap) -> g.impact = Blocks_verdict)
                c.completeness_gaps)
        checks
    in
    if has_blocking_inconclusive then Inconclusive else Satisfied)
;;

let judgment_basis_hash ~contract_id ~schema_version : string =
  let input =
    Printf.sprintf
      "%s|%s|%s|manifest.json|contract.json|%d"
      contract_id
      Cdal_types.loader_semantics_version_phase1
      Cdal_types.schema_compat_mode_v1
      schema_version
  in
  let hash = Digest.string input |> Digest.to_hex in
  "md5:" ^ hash
;;

let judge (b : Cdal_loader.loaded_bundle) : Cdal_types.contract_verdict =
  let checks =
    [ check_execution_mode b
    ; check_risk_class b
    ; check_contract_snapshot b
    ; check_required_artifact b
    ; check_review_requirement b
    ; check_result_status b
    ]
  in
  let status = derive_status checks in
  let findings =
    List.concat_map (fun (c : Cdal_types.check_result) -> c.findings) checks
  in
  let completeness_gaps =
    List.concat_map (fun (c : Cdal_types.check_result) -> c.completeness_gaps) checks
  in
  let basis_hash =
    judgment_basis_hash
      ~contract_id:b.proof.contract_id
      ~schema_version:b.proof.schema_version
  in
  let verdict_without_hash : Cdal_types.contract_verdict =
    { run_id = b.proof.run_id
    ; contract_id = b.proof.contract_id
    ; claim_scope = Cdal_types.claim_scope_phase1
    ; judgment_basis_hash = basis_hash
    ; judgment_hash = ""
    ; loader_semantics_version = Cdal_types.loader_semantics_version_phase1
    ; schema_compat_mode = Cdal_types.schema_compat_mode_v1
    ; status
    ; findings
    ; completeness_gaps
    ; check_results = checks
    }
  in
  let judgment_hash = Cdal_types.compute_judgment_hash verdict_without_hash in
  { verdict_without_hash with judgment_hash }
;;
