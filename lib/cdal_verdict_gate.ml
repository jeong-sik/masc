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
    let finding_details =
      List.map
        (fun (f : Cdal_types.contract_finding) ->
           Printf.sprintf
             "check=%s observed=%s expected=%s"
             f.check_id
             (Yojson.Safe.to_string f.observed)
             (Yojson.Safe.to_string f.expected))
        v.findings
    in
    let msg =
      Printf.sprintf
        "CDAL verdict Violated (run_id=%s, contract=%s). Findings: %s"
        v.run_id
        v.contract_id
        (String.concat "; " finding_details)
    in
    Reject msg
  | Cdal_types.Inconclusive ->
    let blocking_gaps =
      List.filter
        (fun (g : Cdal_types.completeness_gap) -> g.impact = Cdal_types.Blocks_verdict)
        v.completeness_gaps
    in
    if blocking_gaps = []
    then Allow
    else (
      let gap_details =
        List.map
          (fun (g : Cdal_types.completeness_gap) ->
             Printf.sprintf "%s: %s" g.artifact g.reason)
          blocking_gaps
      in
      let review_guidance =
        if
          List.exists
            (fun (g : Cdal_types.completeness_gap) ->
               String.equal g.artifact "evidence/review_warning.json")
            blocking_gaps
        then
          " Submit for verification and approve via the verification FSM before marking \
           done."
        else ""
      in
      let msg =
        Printf.sprintf
          "CDAL verdict Inconclusive with blocking gaps (run_id=%s). Gaps: %s%s"
          v.run_id
          (String.concat "; " gap_details)
          review_guidance
      in
      Reject msg)
;;

let default_base_path () =
  let root =
    match Sys.getenv_opt Env_config_core.data_dir_env_key with
    | Some dir -> dir
    | None -> Filename.concat (Env_config_core.base_path ()) "data"
  in
  Filename.concat root "cdal_verdicts"
;;

let lookup_latest_verdict
      ?base_dir
      ?(limit = Env_config_runtime.Cdal.verdict_lookup_limit ())
      ~task_id
      ()
  : Cdal_types.contract_verdict option
  =
  let base_dir =
    match base_dir with
    | Some dir -> dir
    | None -> default_base_path ()
  in
  let store = Dated_jsonl.create ~base_dir () in
  let recent = Dated_jsonl.read_recent store limit in
  let result =
    List.fold_left
      (fun acc json ->
         match json with
         | `Assoc fields ->
           (match List.assoc_opt "_task_id" fields with
            | Some (`String tid) when tid = task_id ->
              let verdict_fields = List.filter (fun (k, _) -> k <> "_task_id") fields in
              (match Cdal_types.contract_verdict_of_json (`Assoc verdict_fields) with
               | Ok v -> Some v
               | Error _ -> acc)
            | _ -> acc)
         | _ -> acc)
      None
      recent
  in
  (* #10115: distinguish three "verdict not found" cases so the
     operator gets an accurate diagnosis.  The previous WARN
     unconditionally said "older verdicts beyond window are
     silently skipped" — true when the scan saturated [limit],
     misleading when the ledger is empty or the writer pipeline
     is dormant (12-day gap observed in production).  If the
     operator follows the WARN's hint and bumps
     [MASC_CDAL_VERDICT_LOOKUP_LIMIT], they spend cycles
     investigating the wrong layer. *)
  (match result, recent with
   | Some _, _ -> ()
   | None, [] ->
     Log.Task.warn
       "[cdal-gate] task_id=%s: cdal_verdicts ledger is EMPTY at %s. Writer pipeline \
        likely dormant — check that OAS Agent.run emits result.proof and \
        Cdal_eval_v1.persist is reached. (#10115)"
       task_id
       base_dir
   | None, _ when List.length recent >= limit ->
     Log.Task.warn
       "[cdal-gate] task_id=%s: scanned newest %d entries without match; older verdicts \
        beyond window are silently skipped (raise MASC_CDAL_VERDICT_LOOKUP_LIMIT to \
        widen the window)"
       task_id
       limit
   | None, _ ->
     Log.Task.warn
       "[cdal-gate] task_id=%s: no verdict in current ledger window (%d entries scanned, \
        below limit=%d).  Either the task has never been verified, or the writer \
        pipeline is dormant — bumping MASC_CDAL_VERDICT_LOOKUP_LIMIT will not help. \
        (#10115)"
       task_id
       (List.length recent)
       limit);
  result
;;

(* #10115: ledger health introspection.  Walks [base_dir/YYYY-MM/]
   to find the newest [DD.jsonl] file's mtime; lets a boot-time
   health check catch a dormant writer pipeline before any
   strict-contract task tries to gate on a verdict that will
   never arrive. *)
type ledger_health =
  { base_dir : string
  ; total_files : int
  ; latest_mtime : float option
  ; age_seconds : float option
  }

let ledger_health_report ?base_dir () : ledger_health =
  let base_dir =
    match base_dir with
    | Some dir -> dir
    | None -> default_base_path ()
  in
  let collect_jsonl_mtimes () =
    if not (Sys.file_exists base_dir)
    then []
    else (
      let month_dirs =
        try
          Sys.readdir base_dir
          |> Array.to_list
          |> List.filter (fun name ->
            let full = Filename.concat base_dir name in
            try Sys.is_directory full with
            | Sys_error _ -> false)
        with
        | Sys_error _ -> []
      in
      List.concat_map
        (fun month ->
           let dir = Filename.concat base_dir month in
           try
             Sys.readdir dir
             |> Array.to_list
             |> List.filter_map (fun name ->
               if Filename.check_suffix name ".jsonl"
               then (
                 let full = Filename.concat dir name in
                 try Some (Unix.stat full).st_mtime with
                 | Unix.Unix_error _ -> None)
               else None)
           with
           | Sys_error _ -> [])
        month_dirs)
  in
  let mtimes = collect_jsonl_mtimes () in
  let latest_mtime =
    match mtimes with
    | [] -> None
    | _ -> Some (List.fold_left max neg_infinity mtimes)
  in
  let age_seconds = Option.map (fun m -> Time_compat.now () -. m) latest_mtime in
  { base_dir; total_files = List.length mtimes; latest_mtime; age_seconds }
;;

(* Threshold for boot-time staleness WARN.  7 days picks up the
   12-day production dormancy from #10115 with margin while not
   firing on transient quiet periods. *)
let stale_age_seconds_default = 7. *. 86400.

let log_ledger_health_warn_if_stale
      ?base_dir
      ?(stale_age_seconds = stale_age_seconds_default)
      ()
  : ledger_health
  =
  let report = ledger_health_report ?base_dir () in
  (match report.latest_mtime, report.age_seconds with
   | None, _ ->
     Log.Task.warn
       "[cdal-gate] ledger health: %s has NO verdict files. Writer pipeline likely never \
        started or never reached Cdal_eval_v1.persist. (#10115)"
       report.base_dir
   | Some _, Some age when age > stale_age_seconds ->
     let days = age /. 86400. in
     Log.Task.warn
       "[cdal-gate] ledger health: latest verdict file is %.1f days old (threshold %.1f \
        days; %d files scanned in %s).  Writer pipeline likely dormant — strict-contract \
        tasks will fail until restored. (#10115)"
       days
       (stale_age_seconds /. 86400.)
       report.total_files
       report.base_dir
   | Some _, _ -> ());
  report
;;

(* --- Attribution envelope conversion ---
   Layer 1 of the attribution rollout. Lets emitters surface a typed
   verdict envelope alongside the existing string-return gate_check.
   Defined before gate_check so the latter can record into the ring
   buffer without forward-referencing. *)

let blocking_gap_count (v : Cdal_types.contract_verdict) : int =
  List.length
    (List.filter
       (fun (g : Cdal_types.completeness_gap) -> g.impact = Cdal_types.Blocks_verdict)
       v.completeness_gaps)
;;

let evidence_of_verdict (v : Cdal_types.contract_verdict) : Yojson.Safe.t =
  `Assoc
    [ "run_id", `String v.run_id
    ; "contract_id", `String v.contract_id
    ; "status", `String (Cdal_types.contract_status_to_string v.status)
    ; "findings_count", `Int (List.length v.findings)
    ; "gaps_count", `Int (List.length v.completeness_gaps)
    ; "blocking_gaps_count", `Int (blocking_gap_count v)
    ]
;;

let strict_gate_label = "cdal_verdict"
let advisory_gate_label = "cdal_verdict_advisory"

let to_attribution ?(gate_label = strict_gate_label) (v : Cdal_types.contract_verdict)
  : Attribution.t
  =
  let evidence = evidence_of_verdict v in
  match check_verdict v with
  | Allow -> Attribution.passed ~origin:Det ~gate:gate_label ~evidence
  | Reject reason ->
    Attribution.policy_failed ~origin:Det ~gate:gate_label ~evidence ~reason
;;

let attribution_for_missing_verdict ?(gate_label = strict_gate_label) ~task_id ()
  : Attribution.t
  =
  let evidence = `Assoc [ "task_id", `String task_id ] in
  Attribution.policy_failed
    ~origin:Det
    ~gate:gate_label
    ~evidence
    ~reason:
      (Printf.sprintf
         "No CDAL verdict found for task %s. Submit evidence before completing."
         task_id)
;;

let gate_check ?base_dir ?(gate_label = strict_gate_label) ~task_id () : string option =
  match lookup_latest_verdict ?base_dir ~task_id () with
  | None ->
    Dashboard_attribution.record (attribution_for_missing_verdict ~gate_label ~task_id ());
    Some
      (Printf.sprintf
         "No CDAL verdict found for task %s. Submit evidence before completing."
         task_id)
  | Some verdict ->
    Dashboard_attribution.record (to_attribution ~gate_label verdict);
    (match check_verdict verdict with
     | Allow -> None
     | Reject msg -> Some msg)
;;
