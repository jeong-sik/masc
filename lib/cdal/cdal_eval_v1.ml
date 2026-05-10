(** Cdal_eval_v1 -- Phase 1A integration facade.

    @since CDAL Phase 1A *)

type eval_outcome =
  | Verdict of Cdal_types.contract_verdict
      * Cdal_friction_projection.friction_projection option
  | Load_failure of Cdal_loader.load_error * Cdal_types.contract_verdict

(* ================================================================ *)
(* Inconclusive verdict for load failures                           *)
(* ================================================================ *)

let load_failure_artifact = function
  | Cdal_loader.Manifest_not_found _ | Cdal_loader.Manifest_parse_error _ ->
    "manifest.json"
  | Cdal_loader.Contract_not_found _ | Cdal_loader.Contract_parse_error _ ->
    "contract.json"
  | Cdal_loader.Schema_unsupported _ -> "manifest.json"
  | Cdal_loader.Ref_resolution_error _ -> "contract.json"

let synthesize_inconclusive ~(proof : Masc_mcp_cdal_runtime.Cdal_proof.t)
    (err : Cdal_loader.load_error) : Cdal_types.contract_verdict =
  let gap : Cdal_types.completeness_gap = {
    artifact = load_failure_artifact err;
    reason = Cdal_loader.load_error_to_string err;
    impact = Blocks_verdict;
  } in
  let basis_input =
    Printf.sprintf "%s|%s|%s|load_failure"
      proof.contract_id
      Cdal_types.loader_semantics_version_phase1
      Cdal_types.schema_compat_mode_v1 in
  let basis_hash =
    "md5:" ^ (Digest.string basis_input |> Digest.to_hex) in
  let verdict_without_hash : Cdal_types.contract_verdict = {
    run_id = proof.run_id;
    contract_id = proof.contract_id;
    claim_scope = Cdal_types.claim_scope_phase1;
    judgment_basis_hash = basis_hash;
    judgment_hash = "";
    loader_semantics_version = Cdal_types.loader_semantics_version_phase1;
    schema_compat_mode = Cdal_types.schema_compat_mode_v1;
    status = Inconclusive;
    findings = [];
    completeness_gaps = [gap];
    check_results = [];
  } in
  let judgment_hash = Cdal_types.compute_judgment_hash verdict_without_hash in
  { verdict_without_hash with judgment_hash }

(* ================================================================ *)
(* Evaluation pipeline                                              *)
(* ================================================================ *)

let evaluate ~(store : Masc_mcp_cdal_runtime.Proof_store.config)
    (proof : Masc_mcp_cdal_runtime.Cdal_proof.t) : eval_outcome =
  match Cdal_loader.load ~store proof with
  | Ok bundle ->
    let verdict = Cdal_judge.judge bundle in
    let friction = Cdal_friction_projection.project_single_run
      ~store ~completeness_gaps:verdict.completeness_gaps proof in
    Verdict (verdict, friction)
  | Error err ->
    let verdict = synthesize_inconclusive ~proof err in
    Load_failure (err, verdict)

let verdict_of_outcome = function
  | Verdict (v, _) -> v
  | Load_failure (_, v) -> v

let friction_of_outcome = function
  | Verdict (_, f) -> f
  | Load_failure _ -> None

(* ================================================================ *)
(* JSONL persistence                                                *)
(* ================================================================ *)

let default_base_path () =
  let root =
    match Sys.getenv_opt Env_config_core.data_dir_env_key with
    | Some dir -> dir
    | None -> Filename.concat (Env_config_core.base_path ()) "data"
  in
  Filename.concat root "cdal_verdicts"

let persist ?base_dir ?task_id
    (verdict : Cdal_types.contract_verdict) : unit =
  let base_dir =
    match base_dir with
    | Some dir -> dir
    | None -> default_base_path ()
  in
  let store = Dated_jsonl.create ~base_dir () in
  let json = Cdal_types.contract_verdict_to_json verdict in
  let envelope = match task_id with
    | None -> json
    | Some tid ->
      match json with
      | `Assoc fields -> `Assoc (("_task_id", `String tid) :: fields)
      | other -> other
  in
  Dated_jsonl.append store envelope
