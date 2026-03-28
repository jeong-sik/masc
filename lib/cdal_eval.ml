(** Cdal_eval -- Phase 0 structural verdict over CDAL proof bundles.

    @since Phase 0 -- CDAL proof tap *)

type severity =
  | Ok
  | Warn of string
  | Fail of string

type evidence_check = {
  has_tool_traces : bool;
  has_raw_evidence : bool;
  has_checkpoint : bool;
  completed_normally : bool;
}

type violation_summary = {
  violation_ref_count : int;
  mode_was_downgraded : bool;
  downgrade_reason : string option;
}

type eval_result = {
  evidence : evidence_check;
  violations : violation_summary;
  overall : severity;
  run_id : string;
  contract_id : string;
  result_status : Agent_sdk.Cdal_proof.result_status;
  evaluated_at : float;
}

let string_contains ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen then false
  else
    let rec check i =
      if i > hlen - nlen then false
      else if String.sub haystack i nlen = needle then true
      else check (i + 1)
    in
    check 0

let count_violation_refs (refs : Agent_sdk.Cdal_proof.artifact_ref list) : int =
  List.length
    (List.filter (fun r -> string_contains ~needle:"mode_violations" r) refs)

let make_evidence_check (p : Agent_sdk.Cdal_proof.t) : evidence_check =
  {
    has_tool_traces = p.tool_trace_refs <> [];
    has_raw_evidence = p.raw_evidence_refs <> [];
    has_checkpoint = p.checkpoint_ref <> None;
    completed_normally = p.result_status = Completed;
  }

let make_violation_summary (p : Agent_sdk.Cdal_proof.t) : violation_summary =
  let downgraded =
    p.effective_execution_mode <> p.requested_execution_mode
  in
  {
    violation_ref_count = count_violation_refs p.raw_evidence_refs;
    mode_was_downgraded = downgraded;
    downgrade_reason =
      (if downgraded then Some p.mode_decision_source else None);
  }

let compute_overall ~(evidence : evidence_check)
    ~(violations : violation_summary)
    ~(result_status : Agent_sdk.Cdal_proof.result_status) : severity =
  match result_status with
  | Cancelled -> Fail "cancelled by contract"
  | Errored -> Warn "execution error"
  | Timed_out -> Warn "execution timed out"
  | Completed ->
    if violations.violation_ref_count > 0 then
      Warn
        (Printf.sprintf "%d mode violation(s) detected"
           violations.violation_ref_count)
    else if
      (not evidence.has_tool_traces) && (not evidence.has_raw_evidence)
    then
      Warn "no evidence produced"
    else Ok

let evaluate (p : Agent_sdk.Cdal_proof.t) : eval_result =
  let evidence = make_evidence_check p in
  let violations = make_violation_summary p in
  let overall = compute_overall ~evidence ~violations ~result_status:p.result_status in
  {
    evidence;
    violations;
    overall;
    run_id = p.run_id;
    contract_id = p.contract_id;
    result_status = p.result_status;
    evaluated_at = Unix.gettimeofday ();
  }

let is_acceptable (r : eval_result) : bool =
  match r.overall with
  | Ok | Warn _ -> true
  | Fail _ -> false

let severity_to_string = function
  | Ok -> "ok"
  | Warn reason -> Printf.sprintf "warn: %s" reason
  | Fail reason -> Printf.sprintf "fail: %s" reason

let severity_to_json = function
  | Ok -> `Assoc [("level", `String "ok")]
  | Warn reason -> `Assoc [("level", `String "warn"); ("reason", `String reason)]
  | Fail reason -> `Assoc [("level", `String "fail"); ("reason", `String reason)]

let evidence_check_to_json (e : evidence_check) : Yojson.Safe.t =
  `Assoc [
    ("has_tool_traces", `Bool e.has_tool_traces);
    ("has_raw_evidence", `Bool e.has_raw_evidence);
    ("has_checkpoint", `Bool e.has_checkpoint);
    ("completed_normally", `Bool e.completed_normally);
  ]

let violation_summary_to_json (v : violation_summary) : Yojson.Safe.t =
  `Assoc [
    ("violation_ref_count", `Int v.violation_ref_count);
    ("mode_was_downgraded", `Bool v.mode_was_downgraded);
    ("downgrade_reason",
     match v.downgrade_reason with
     | Some r -> `String r
     | None -> `Null);
  ]

let recommendation (r : eval_result) : string option =
  match r.overall with
  | Ok -> None
  | Fail "cancelled by contract" ->
    Some "contract risk_class or requested_execution_mode is incompatible with keeper capabilities; adjust scope_kind in keeper config"
  | Fail reason -> Some (Printf.sprintf "investigate failure: %s" reason)
  | Warn reason ->
    if r.violations.violation_ref_count > 0 then
      if r.violations.mode_was_downgraded then
        Some "mode was downgraded and violations detected; widen scope_kind to match actual tool usage or remove mutating tools"
      else
        Some "mode violations detected; restrict tools to match execution mode or widen scope_kind"
    else if not r.evidence.completed_normally then
      Some "run did not complete normally; check max_turns, timeout, or model availability"
    else
      Some (Printf.sprintf "review: %s" reason)

let to_json (r : eval_result) : Yojson.Safe.t =
  let base = [
    ("run_id", `String r.run_id);
    ("contract_id", `String r.contract_id);
    ("result_status",
     `String (Agent_sdk.Cdal_proof.show_result_status r.result_status));
    ("evidence", evidence_check_to_json r.evidence);
    ("violations", violation_summary_to_json r.violations);
    ("overall", severity_to_json r.overall);
    ("evaluated_at", `Float r.evaluated_at);
  ] in
  let extra = match recommendation r with
    | Some rec_text -> [("recommendation", `String rec_text)]
    | None -> []
  in
  `Assoc (base @ extra)

(* ================================================================ *)
(* JSONL Persistence                                                 *)
(* ================================================================ *)

let store_ref : Dated_jsonl.t option ref = ref None

let base_path () =
  let root = try Sys.getenv "MASC_DATA_DIR"
    with Not_found ->
      try Filename.concat (Sys.getenv "ME_ROOT") "data"
      with Not_found -> "data"
  in
  Filename.concat root "cdal_evals"

let get_store () =
  match !store_ref with
  | Some s -> s
  | None ->
    let s = Dated_jsonl.create ~base_dir:(base_path ()) () in
    store_ref := Some s;
    s

let reset_store_for_testing () = store_ref := None

let set_store_for_testing ~base_dir =
  store_ref := Some (Dated_jsonl.create ~base_dir ())

let persist (r : eval_result) : unit =
  Dated_jsonl.append (get_store ()) (to_json r)
