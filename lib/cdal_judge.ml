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

(* ================================================================ *)
(* Exec-outcome verifiable markers (Legendary Bash P6 Tick 15).     *)
(*                                                                  *)
(* The goal is to lift structured signals out of a finished bash    *)
(* invocation *without* the verifier cascade having to regex the    *)
(* raw output.  Heuristics here are deliberately conservative:      *)
(* when we cannot pin the output to a known producer (dune, cargo,  *)
(* eslint, git status), we return [] and let the caller keep the    *)
(* raw bytes as evidence.  False positives poison the cascade, so   *)
(* confidence defaults to [`Heuristic]; only [`Exact] markers are   *)
(* granted "proof" status downstream.                               *)
(* ================================================================ *)

type marker_confidence = [ `Exact | `Heuristic ]

type verifiable_marker =
  | Test_pass of { count : int; confidence : marker_confidence }
  | Test_fail of { count : int; confidence : marker_confidence }
  | Build_ok  of { confidence : marker_confidence }
  | Build_fail of { confidence : marker_confidence }
  | Lint_clean of { confidence : marker_confidence }
  | Lint_dirty of { count : int; confidence : marker_confidence }
  | Git_clean of { confidence : marker_confidence }
  | Git_dirty of { confidence : marker_confidence }
  | Git_not_a_repo

let conf_to_string = function
  | `Exact -> "exact"
  | `Heuristic -> "heuristic"

let marker_to_string = function
  | Test_pass { count; confidence } ->
      Printf.sprintf "test_pass:%d:%s" count (conf_to_string confidence)
  | Test_fail { count; confidence } ->
      Printf.sprintf "test_fail:%d:%s" count (conf_to_string confidence)
  | Build_ok { confidence } -> "build_ok:" ^ conf_to_string confidence
  | Build_fail { confidence } -> "build_fail:" ^ conf_to_string confidence
  | Lint_clean { confidence } -> "lint_clean:" ^ conf_to_string confidence
  | Lint_dirty { count; confidence } ->
      Printf.sprintf "lint_dirty:%d:%s" count (conf_to_string confidence)
  | Git_clean { confidence } -> "git_clean:" ^ conf_to_string confidence
  | Git_dirty { confidence } -> "git_dirty:" ^ conf_to_string confidence
  | Git_not_a_repo -> "git_not_a_repo:exact"

(* --- low-level text helpers (no re lib; keep deps thin) --- *)

let contains_sub s sub =
  let ls = String.length s and lsub = String.length sub in
  if lsub = 0 then true
  else if lsub > ls then false
  else
    let rec loop i =
      if i + lsub > ls then false
      else if String.sub s i lsub = sub then true
      else loop (i + 1)
    in
    loop 0

let contains_ci s sub =
  contains_sub (String.lowercase_ascii s) (String.lowercase_ascii sub)

(* Counts occurrences of a fixed substring. *)
let count_sub s sub =
  let ls = String.length s and lsub = String.length sub in
  if lsub = 0 || lsub > ls then 0
  else
    let rec loop i acc =
      if i + lsub > ls then acc
      else if String.sub s i lsub = sub then loop (i + lsub) (acc + 1)
      else loop (i + 1) acc
    in
    loop 0 0

(* Producer classifiers — match on a few unambiguous strings each
   tool emits.  The raw stream is concatenated stdout ^ stderr. *)

let looks_like_dune_build out =
  contains_sub out "dune build" ||
  contains_sub out "ocamlc " ||
  contains_sub out "ocamlopt "

let looks_like_dune_runtest out =
  contains_sub out "dune runtest" ||
  contains_sub out "Alcotest" ||
  contains_sub out "Testing `"

let looks_like_cargo out =
  contains_sub out "Compiling " ||
  contains_sub out "running " && contains_sub out " target/"

let looks_like_git_status out =
  contains_sub out "nothing to commit" ||
  contains_sub out "Changes not staged" ||
  contains_sub out "Untracked files" ||
  contains_sub out "Changes to be committed"

let looks_like_lint_eslint out =
  contains_ci out "eslint" || contains_ci out "problem"

(* pytest characteristic banners.  The "test session starts" banner
   is the canonical signal emitted by pytest >= 3.x (surrounded by
   variable-length "=" padding).  We also key off the common " pytest"
   invocation token so that early-exit failures with no session banner
   (e.g. collection errors) still classify as pytest. *)
let looks_like_pytest out =
  contains_sub out "test session starts" ||
  contains_sub out " pytest " ||
  contains_sub out "pytest "

(* Test count extraction.  Alcotest / cargo-test lines commonly look
   like one of:

     "Test Successful in 0.003s. 8 tests run."      (int BEFORE marker)
     "12 tests passed."                              (int BEFORE marker)
     "test result: ok. 12 passed; 0 failed; ..."    (int AFTER marker)

   Strategy: per line, for each known marker we check whether the
   marker appears and then scan the line in the appropriate direction
   starting from the marker position.  First match wins; 0 means
   "no producer-specific pattern matched". *)

let split_lines s =
  String.split_on_char '\n' s

let first_int_before line pos =
  let rec skip_ws i =
    if i < 0 then i
    else if line.[i] = ' ' || line.[i] = '\t' then skip_ws (i - 1)
    else i
  in
  let end_ = skip_ws (pos - 1) in
  if end_ < 0 then None
  else if not (line.[end_] >= '0' && line.[end_] <= '9') then None
  else
    let rec start_of i =
      if i < 0 then 0
      else if line.[i] >= '0' && line.[i] <= '9' then start_of (i - 1)
      else i + 1
    in
    let start = start_of end_ in
    int_of_string_opt (String.sub line start (end_ - start + 1))

let first_int_after line pos =
  let ls = String.length line in
  let rec skip_ws i =
    if i >= ls then i
    else if line.[i] = ' ' || line.[i] = '\t' then skip_ws (i + 1)
    else i
  in
  let start = skip_ws pos in
  if start >= ls then None
  else if not (line.[start] >= '0' && line.[start] <= '9') then None
  else
    let buf = Buffer.create 8 in
    let rec loop i =
      if i >= ls then ()
      else
        let c = line.[i] in
        if c >= '0' && c <= '9' then begin
          Buffer.add_char buf c; loop (i + 1)
        end
    in
    loop start;
    int_of_string_opt (Buffer.contents buf)

let find_sub_in line sub =
  let ls = String.length line and lsub = String.length sub in
  if lsub = 0 || lsub > ls then None
  else
    let rec loop i =
      if i + lsub > ls then None
      else if String.sub line i lsub = sub then Some i
      else loop (i + 1)
    in
    loop 0

(* pytest summary line:
     "===== 12 passed in 0.45s ====="
     "===== 5 failed, 7 passed in 1.2s ====="
     "===== 12 passed, 1 skipped in 0.4s ====="
   Strategy: require the leading "=====" banner to distinguish from
   any other "N passed" substring that might sneak in from framework
   docs or error context.  [tag] is either "passed" or "failed". *)
let pytest_count_from_output ~tag out =
  let has_banner line =
    match find_sub_in line "=====" with
    | Some _ -> true
    | None -> false
  in
  let needle = " " ^ tag in
  let rec per_line = function
    | [] -> 0
    | line :: rest ->
        if has_banner line then
          match find_sub_in line needle with
          | None -> per_line rest
          | Some pos ->
              (match first_int_before line pos with
               | Some n -> n
               | None -> per_line rest)
        else
          per_line rest
  in
  per_line (split_lines out)

let test_count_from_output out =
  let markers_before = [ "tests run"; "tests passed"; "test passed" ] in
  let markers_after = [ "test result: ok. "; "passed:" ] in
  let rec per_line = function
    | [] -> 0
    | line :: rest ->
        let found_before =
          List.find_map (fun m ->
            match find_sub_in line m with
            | None -> None
            | Some pos -> first_int_before line pos) markers_before
        in
        (match found_before with
         | Some n -> n
         | None ->
             let found_after =
               List.find_map (fun m ->
                 match find_sub_in line m with
                 | None -> None
                 | Some pos -> first_int_after line (pos + String.length m))
                 markers_after
             in
             (match found_after with
              | Some n -> n
              | None -> per_line rest))
  in
  per_line (split_lines out)

let of_exec_outcome ~semantic ~stdout ~stderr =
  let out = stdout ^ "\n" ^ stderr in
  let semantic : Masc_exec.Exec_semantic.t = semantic in
  match semantic with
  | `Git_not_a_repo -> [ Git_not_a_repo ]
  | `Ok ->
      if looks_like_pytest out then
        let n = pytest_count_from_output ~tag:"passed" out in
        [ Test_pass { count = n; confidence = `Heuristic } ]
      else if looks_like_dune_runtest out then
        let n = test_count_from_output out in
        [ Test_pass { count = n; confidence = `Heuristic } ]
      else if looks_like_dune_build out then
        [ Build_ok { confidence = `Heuristic } ]
      else if looks_like_cargo out then
        [ Build_ok { confidence = `Heuristic } ]
      else if looks_like_git_status out then begin
        if contains_sub out "nothing to commit" then
          [ Git_clean { confidence = `Exact } ]
        else
          [ Git_dirty { confidence = `Exact } ]
      end
      else if looks_like_lint_eslint out then begin
        (* No problem lines → clean. *)
        if not (contains_ci out "error") && not (contains_ci out "warning")
        then [ Lint_clean { confidence = `Heuristic } ]
        else
          let n = count_sub out "error " + count_sub out "warning " in
          [ Lint_dirty { count = n; confidence = `Heuristic } ]
      end
      else []
  | `Fail _ ->
      if looks_like_pytest out then
        let n = pytest_count_from_output ~tag:"failed" out in
        [ Test_fail { count = n; confidence = `Heuristic } ]
      else if looks_like_dune_runtest out then
        let n = test_count_from_output out in
        [ Test_fail { count = n; confidence = `Heuristic } ]
      else if looks_like_dune_build out then
        [ Build_fail { confidence = `Heuristic } ]
      else if looks_like_cargo out then
        [ Build_fail { confidence = `Heuristic } ]
      else if looks_like_lint_eslint out then
        let n = count_sub out "error " + count_sub out "warning " in
        [ Lint_dirty { count = n; confidence = `Heuristic } ]
      else []
  | `Timeout _ | `Signaled _ | `Oom_killed -> []
  | `Policy_denied _ | `Tool_missing _ | `Permission_denied _ -> []
