(** Cdal_verdict_gate -- Deterministic gate that blocks task completion
    when the latest CDAL verdict is Violated or Inconclusive with blocking gaps.

    Reads from cdal_verdicts/*.jsonl (produced by Cdal_eval_v1.persist).
    Gate logic is pure: Satisfied -> Allow, Violated -> Reject, etc. *)

type gate_result =
  | Allow
  | Reject of string

let check_verdict (v : Cdal_types.contract_verdict) : gate_result =
  match v.status with
  | Cdal_types.Satisfied -> Allow
  | Cdal_types.Violated ->
    let finding_details = List.map (fun (f : Cdal_types.contract_finding) ->
      Printf.sprintf "check=%s observed=%s expected=%s"
        f.check_id
        (Yojson.Safe.to_string f.observed)
        (Yojson.Safe.to_string f.expected)
    ) v.findings in
    let msg = Printf.sprintf
      "CDAL verdict Violated (run_id=%s, contract=%s). Findings: %s"
      v.run_id v.contract_id
      (String.concat "; " finding_details)
    in
    Reject msg
  | Cdal_types.Inconclusive ->
    let blocking_gaps = List.filter (fun (g : Cdal_types.completeness_gap) ->
      g.impact = Cdal_types.Blocks_verdict
    ) v.completeness_gaps in
    if blocking_gaps = [] then Allow
    else
      let gap_details = List.map (fun (g : Cdal_types.completeness_gap) ->
        Printf.sprintf "%s: %s" g.artifact g.reason
      ) blocking_gaps in
      let review_guidance =
        if List.exists (fun (g : Cdal_types.completeness_gap) ->
             String.equal g.artifact "evidence/review_warning.json")
            blocking_gaps
        then
          " Submit for verification and approve via the verification FSM before marking done."
        else ""
      in
      let msg = Printf.sprintf
        "CDAL verdict Inconclusive with blocking gaps (run_id=%s). Gaps: %s%s"
        v.run_id (String.concat "; " gap_details) review_guidance
      in
      Reject msg

let default_base_path =
  let root =
    match Sys.getenv_opt "MASC_DATA_DIR" with
    | Some dir -> dir
    | None -> Filename.concat (Env_config_core.base_path ()) "data"
  in
  Filename.concat root "cdal_verdicts"

let lookup_latest_verdict ?(base_dir = default_base_path)
    ?(limit = Env_config_runtime.Cdal.verdict_lookup_limit ())
    ~task_id () : Cdal_types.contract_verdict option =
  let store = Dated_jsonl.create ~base_dir () in
  let recent = Dated_jsonl.read_recent store limit in
  let result = List.fold_left (fun acc json ->
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "_task_id" fields with
       | Some (`String tid) when tid = task_id ->
         let verdict_fields = List.filter (fun (k, _) -> k <> "_task_id") fields in
         (match Cdal_types.contract_verdict_of_json (`Assoc verdict_fields) with
          | Ok v -> Some v
          | Error _ -> acc)
       | _ -> acc)
    | _ -> acc
  ) None recent in
  (* If we scanned the full limit and still no match, the verdict may exist
     in older entries outside the scan window. Log a WARN so debugging is
     possible instead of silent skipping. Issue #7546. *)
  (if result = None && List.length recent >= limit then
    Log.Task.warn
      "[cdal-gate] lookup_latest_verdict: scanned limit=%d without finding task_id=%s; \
       older verdicts beyond window are silently skipped (MASC_CDAL_VERDICT_LOOKUP_LIMIT)"
      limit task_id);
  result

let gate_check ?(base_dir = default_base_path) ~task_id () : string option =
  match lookup_latest_verdict ~base_dir ~task_id () with
  | None ->
    Some (Printf.sprintf
      "No CDAL verdict found for task %s. Submit evidence before completing."
      task_id)
  | Some verdict ->
    match check_verdict verdict with
    | Allow -> None
    | Reject msg -> Some msg

(* --- Attribution envelope conversion ---
   Layer 1 of the attribution rollout. Lets emitters surface a typed
   verdict envelope alongside the existing string-return gate_check. *)

let blocking_gap_count (v : Cdal_types.contract_verdict) : int =
  List.length
    (List.filter
       (fun (g : Cdal_types.completeness_gap) ->
         g.impact = Cdal_types.Blocks_verdict)
       v.completeness_gaps)

let evidence_of_verdict (v : Cdal_types.contract_verdict) : Yojson.Safe.t =
  `Assoc [
    ("run_id", `String v.run_id);
    ("contract_id", `String v.contract_id);
    ("status", `String (Cdal_types.contract_status_to_string v.status));
    ("findings_count", `Int (List.length v.findings));
    ("gaps_count", `Int (List.length v.completeness_gaps));
    ("blocking_gaps_count", `Int (blocking_gap_count v));
  ]

let to_attribution (v : Cdal_types.contract_verdict) : Attribution.t =
  let evidence = evidence_of_verdict v in
  match check_verdict v with
  | Allow ->
    Attribution.passed ~origin:Det ~gate:"cdal_verdict" ~evidence
  | Reject reason ->
    Attribution.policy_failed ~origin:Det ~gate:"cdal_verdict" ~evidence ~reason

let attribution_for_missing_verdict ~task_id : Attribution.t =
  let evidence = `Assoc [ ("task_id", `String task_id) ] in
  Attribution.policy_failed ~origin:Det ~gate:"cdal_verdict" ~evidence
    ~reason:
      (Printf.sprintf
         "No CDAL verdict found for task %s. Submit evidence before completing."
         task_id)
