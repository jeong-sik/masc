(** Cdal_judge -- Phase 1A contract judge with 5 active checks.

    @since CDAL Phase 1A *)

(* ================================================================ *)
(* Check 1: Execution mode                                          *)
(* ================================================================ *)

let check_execution_mode (b : Cdal_loader.loaded_bundle) : Cdal_types.check_result =
  let check_id = "runtime.requested_execution_mode" in
  let proof = b.proof in
  let contract_mode =
    b.contract.runtime_constraints.requested_execution_mode in
  let proof_requested = proof.requested_execution_mode in
  let proof_effective = proof.effective_execution_mode in
  (* Propagation: proof.requested must match contract.runtime_constraints.requested *)
  let propagation_ok =
    Agent_sdk.Execution_mode.equal proof_requested contract_mode in
  (* No-upward-escalation: effective <= requested *)
  let escalation_ok =
    Agent_sdk.Execution_mode.can_serve
      ~requested:proof_requested ~effective:proof_effective in
  if propagation_ok && escalation_ok then
    { check_id; status = Satisfied; findings = []; completeness_gaps = [] }
  else
    let findings = ref [] in
    if not propagation_ok then
      findings := ({ Cdal_types.
        check_id;
        event_id = None;
        observed = `String (Agent_sdk.Execution_mode.to_string proof_requested);
        expected = `String (Agent_sdk.Execution_mode.to_string contract_mode);
        trace_ref = None;
      } : Cdal_types.contract_finding) :: !findings;
    if not escalation_ok then
      findings := ({ Cdal_types.
        check_id;
        event_id = Some "escalation";
        observed = `String (Agent_sdk.Execution_mode.to_string proof_effective);
        expected = `String
          (Printf.sprintf "<= %s"
             (Agent_sdk.Execution_mode.to_string proof_requested));
        trace_ref = None;
      } : Cdal_types.contract_finding) :: !findings;
    { check_id; status = Violated;
      findings = List.rev !findings;
      completeness_gaps = [] }

(* ================================================================ *)
(* Check 2: Risk class                                              *)
(* ================================================================ *)

let check_risk_class (b : Cdal_loader.loaded_bundle) : Cdal_types.check_result =
  let check_id = "runtime.risk_class" in
  let contract_risk = b.contract.runtime_constraints.risk_class in
  let proof_risk = b.proof.risk_class in
  if Agent_sdk.Risk_class.equal contract_risk proof_risk then
    { check_id; status = Satisfied; findings = []; completeness_gaps = [] }
  else
    { check_id; status = Violated;
      findings = [{
        check_id;
        event_id = None;
        observed = `String (Agent_sdk.Risk_class.to_string proof_risk);
        expected = `String (Agent_sdk.Risk_class.to_string contract_risk);
        trace_ref = None;
      }];
      completeness_gaps = [] }

(* ================================================================ *)
(* Check 3: Contract snapshot                                       *)
(* ================================================================ *)

let check_contract_snapshot (b : Cdal_loader.loaded_bundle) : Cdal_types.check_result =
  let check_id = "proof.contract_snapshot" in
  let proof_contract_id = b.proof.contract_id in
  let recomputed = b.recomputed_contract_id in
  if String.equal proof_contract_id recomputed then
    { check_id; status = Satisfied; findings = []; completeness_gaps = [] }
  else
    { check_id; status = Violated;
      findings = [{
        check_id;
        event_id = None;
        observed = `String proof_contract_id;
        expected = `String recomputed;
        trace_ref = None;
      }];
      completeness_gaps = [] }

(* ================================================================ *)
(* Check 4: Required artifact                                       *)
(* ================================================================ *)

let check_required_artifact (_b : Cdal_loader.loaded_bundle) : Cdal_types.check_result =
  (* The loader already verified manifest.json and contract.json exist
     and are parseable. If the loader succeeded, this check is Satisfied. *)
  { check_id = "proof.required_artifact";
    status = Satisfied;
    findings = [];
    completeness_gaps = [] }

(* ================================================================ *)
(* Check 5: Review requirement                                      *)
(* ================================================================ *)

let review_warning_artifact = "evidence/review_warning.json"

let has_review_warning_ref (proof : Agent_sdk.Cdal_proof.t) : bool =
  List.exists
    (fun ref_ -> String.ends_with ~suffix:review_warning_artifact ref_)
    proof.raw_evidence_refs

let check_review_requirement (b : Cdal_loader.loaded_bundle) : Cdal_types.check_result =
  let check_id = "runtime.review_requirement" in
  match b.contract.runtime_constraints.review_requirement with
  | None ->
    { check_id; status = Satisfied; findings = []; completeness_gaps = [] }
  | Some _ ->
    let reason =
      if has_review_warning_ref b.proof then
        "review_requirement present, but OAS only captured warning-style review evidence; use verification FSM for explicit approval"
      else
        "review_requirement present, but no review evidence artifact was captured; use verification FSM for explicit approval"
    in
    { check_id;
      status = Inconclusive;
      findings = [];
      completeness_gaps = [
        {
          Cdal_types.artifact = review_warning_artifact;
          reason;
          impact = Blocks_verdict;
        };
      ] }

(* ================================================================ *)
(* Verdict derivation                                               *)
(* ================================================================ *)

let derive_status (checks : Cdal_types.check_result list) : Cdal_types.contract_status =
  let has_violated =
    List.exists (fun (c : Cdal_types.check_result) ->
      c.status = Violated) checks in
  if has_violated then Violated
  else
    let has_blocking_inconclusive =
      List.exists (fun (c : Cdal_types.check_result) ->
        c.status = Inconclusive &&
        List.exists (fun (g : Cdal_types.completeness_gap) ->
          g.impact = Blocks_verdict) c.completeness_gaps
      ) checks in
    if has_blocking_inconclusive then Inconclusive
    else Satisfied

let judgment_basis_hash ~contract_id ~schema_version : string =
  let input =
    Printf.sprintf "%s|%s|%s|manifest.json|contract.json|%d"
      contract_id
      Cdal_types.loader_semantics_version_phase1
      Cdal_types.schema_compat_mode_v1
      schema_version in
  let hash = Digest.string input |> Digest.to_hex in
  "md5:" ^ hash

let judge (b : Cdal_loader.loaded_bundle) : Cdal_types.contract_verdict =
  let checks = [
    check_execution_mode b;
    check_risk_class b;
    check_contract_snapshot b;
    check_required_artifact b;
    check_review_requirement b;
  ] in
  let status = derive_status checks in
  let findings =
    List.concat_map (fun (c : Cdal_types.check_result) -> c.findings) checks in
  let completeness_gaps =
    List.concat_map (fun (c : Cdal_types.check_result) ->
      c.completeness_gaps) checks in
  let basis_hash =
    judgment_basis_hash
      ~contract_id:b.proof.contract_id
      ~schema_version:b.proof.schema_version in
  let verdict_without_hash : Cdal_types.contract_verdict = {
    run_id = b.proof.run_id;
    contract_id = b.proof.contract_id;
    claim_scope = Cdal_types.claim_scope_phase1;
    judgment_basis_hash = basis_hash;
    judgment_hash = "";
    loader_semantics_version = Cdal_types.loader_semantics_version_phase1;
    schema_compat_mode = Cdal_types.schema_compat_mode_v1;
    status;
    findings;
    completeness_gaps;
    check_results = checks;
  } in
  let judgment_hash = Cdal_types.compute_judgment_hash verdict_without_hash in
  { verdict_without_hash with judgment_hash }
