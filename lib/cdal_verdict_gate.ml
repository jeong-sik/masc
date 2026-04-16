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

let default_base_path =
  let root =
    match Sys.getenv_opt "MASC_DATA_DIR" with
    | Some dir -> dir
    | None -> Filename.concat (Env_config_core.base_path ()) "data"
  in
  Filename.concat root "cdal_verdicts"

let lookup_latest_verdict ?(base_dir = default_base_path) ~task_id () :
    Cdal_types.contract_verdict option =
  let store = Dated_jsonl.create ~base_dir () in
  let recent = Dated_jsonl.read_recent store 200 in
  List.fold_left (fun acc json ->
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
  ) None recent

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
