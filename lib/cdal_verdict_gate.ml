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
      let msg = Printf.sprintf
        "CDAL verdict Inconclusive with blocking gaps (run_id=%s). Gaps: %s"
        v.run_id (String.concat "; " gap_details)
      in
      Reject msg

(* Share the verdict JSONL path with Cdal_eval_v1 to eliminate duplication.
   Issue #7554. *)
let default_base_path = Cdal_eval_v1.default_base_path

let lookup_latest_verdict ?(base_dir = default_base_path)
    ?(limit = Env_config_runtime.Cdal.verdict_lookup_limit ())
    ~task_id () : Cdal_types.contract_verdict option =
  let store = Dated_jsonl.create ~base_dir () in
  let recent = Dated_jsonl.read_recent store limit in
  (* Issue #7551: decode via typed persisted_verdict.
     Handles both new {task_id, verdict} envelope AND legacy flat+_task_id. *)
  let result = List.fold_left (fun acc json ->
    match Cdal_types.persisted_verdict_of_json json with
    | Ok { task_id = Some tid; verdict } when tid = task_id -> Some verdict
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
