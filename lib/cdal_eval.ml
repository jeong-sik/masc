(** Cdal_eval — Content-based CDAL proof evaluation.

    @since CDAL eval content-based redesign *)

type severity =
  | Ok
  | Warn of string
  | Fail of string

type evidence_content = {
  violations : Violation_record.t list;
  token_usage : Token_usage_record.t list;
  tool_trace_count : int;
  completed_normally : bool;
}

type mode_recommendation = {
  current_mode : Agent_sdk.Execution_mode.t;
  minimum_required : Agent_sdk.Execution_mode.t;
  gap : int;
  offending_tools : string list;
  violation_kinds : Violation_record.violation_kind list;
}

type eval_result = {
  evidence : evidence_content;
  overall : severity;
  recommendation : mode_recommendation option;
  run_id : string;
  contract_id : string;
  result_status : Agent_sdk.Cdal_proof.result_status;
  evaluated_at : float;
}

(* ================================================================ *)
(* Constraint algebra                                                *)
(* ================================================================ *)

let mode_ordinal = function
  | Agent_sdk.Execution_mode.Diagnose -> 0
  | Draft -> 1
  | Execute -> 2

let compute_recommendation ~(effective_mode : Agent_sdk.Execution_mode.t)
    (violations : Violation_record.t list) : mode_recommendation option =
  match violations with
  | [] -> None
  | _ ->
    let max_required = List.fold_left (fun acc v ->
      let req = Violation_record.minimum_required_mode v in
      if mode_ordinal req > mode_ordinal acc then req else acc
    ) effective_mode violations in
    let gap = mode_ordinal max_required - mode_ordinal effective_mode in
    if gap <= 0 then None
    else
      let tools = List.sort_uniq String.compare
        (List.map (fun (v : Violation_record.t) -> v.tool_name) violations) in
      let kinds = List.sort_uniq compare
        (List.map (fun (v : Violation_record.t) -> v.violation_kind) violations) in
      Some {
        current_mode = effective_mode;
        minimum_required = max_required;
        gap;
        offending_tools = tools;
        violation_kinds = kinds;
      }

(* ================================================================ *)
(* Verdict computation                                               *)
(* ================================================================ *)

let compute_overall ~(evidence : evidence_content)
    ~(result_status : Agent_sdk.Cdal_proof.result_status)
    ~(recommendation : mode_recommendation option) : severity =
  match result_status with
  | Cancelled -> Fail "cancelled by contract"
  | Errored -> Warn "execution error"
  | Timed_out -> Warn "execution timed out"
  | Completed ->
    match recommendation with
    | Some r ->
      Warn (Printf.sprintf "%d violation(s) from %s; requires %s (current: %s)"
              (List.length evidence.violations)
              (String.concat ", " r.offending_tools)
              (Agent_sdk.Execution_mode.to_string r.minimum_required)
              (Agent_sdk.Execution_mode.to_string r.current_mode))
    | None ->
      if evidence.tool_trace_count = 0 && evidence.violations = [] then
        Warn "no evidence produced"
      else Ok

(* ================================================================ *)
(* Pure evaluation (no I/O)                                          *)
(* ================================================================ *)

let evaluate_content ~(violations : Violation_record.t list)
    ~(token_usage : Token_usage_record.t list) ~(trace_count : int)
    (p : Agent_sdk.Cdal_proof.t) : eval_result =
  let evidence = {
    violations;
    token_usage;
    tool_trace_count = trace_count;
    completed_normally = p.result_status = Completed;
  } in
  let recommendation =
    compute_recommendation ~effective_mode:p.effective_execution_mode violations in
  let overall = compute_overall ~evidence ~result_status:p.result_status
      ~recommendation in
  {
    evidence;
    overall;
    recommendation;
    run_id = p.run_id;
    contract_id = p.contract_id;
    result_status = p.result_status;
    evaluated_at = Unix.gettimeofday ();
  }

(* ================================================================ *)
(* Artifact-reading evaluation                                       *)
(* ================================================================ *)

let has_exact_subpath (store : Agent_sdk.Proof_store.config) expected
    (ref_ : Agent_sdk.Cdal_proof.artifact_ref) =
  match Agent_sdk.Proof_store.resolve_ref store ref_ with
  | Ok resolved -> String.equal resolved.subpath expected
  | Error _ -> false

let read_violations (store : Agent_sdk.Proof_store.config)
    (refs : Agent_sdk.Cdal_proof.artifact_ref list) : Violation_record.t list =
  List.concat_map (fun ref_ ->
    match Proof_artifact_reader.read_json store ref_ with
    | Ok json ->
      (match Violation_record.of_json_list json with
       | Ok vs -> vs
       | Error _ -> [])
    | Error _ -> []
  ) (List.filter (has_exact_subpath store "evidence/mode_violations.json") refs)

let read_token_usage (store : Agent_sdk.Proof_store.config)
    (refs : Agent_sdk.Cdal_proof.artifact_ref list) : Token_usage_record.t list =
  List.concat_map (fun ref_ ->
    match Proof_artifact_reader.read_json store ref_ with
    | Ok json ->
      (match Token_usage_record.of_json_list json with
       | Ok ts -> ts
       | Error _ -> [])
    | Error _ -> []
  ) (List.filter (has_exact_subpath store "evidence/token_usage.json") refs)

let evaluate ~(store : Agent_sdk.Proof_store.config)
    (p : Agent_sdk.Cdal_proof.t) : eval_result =
  let violations = read_violations store p.raw_evidence_refs in
  let token_usage = read_token_usage store p.raw_evidence_refs in
  let trace_count = List.length p.tool_trace_refs in
  evaluate_content ~violations ~token_usage ~trace_count p

(* ================================================================ *)
(* Severity helpers                                                  *)
(* ================================================================ *)

let is_acceptable (r : eval_result) : bool =
  match r.overall with
  | Ok | Warn _ -> true
  | Fail _ -> false

let severity_to_string = function
  | Ok -> "ok"
  | Warn reason -> Printf.sprintf "warn: %s" reason
  | Fail reason -> Printf.sprintf "fail: %s" reason

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

let severity_to_json = function
  | Ok -> `Assoc [("level", `String "ok")]
  | Warn reason -> `Assoc [("level", `String "warn"); ("reason", `String reason)]
  | Fail reason -> `Assoc [("level", `String "fail"); ("reason", `String reason)]

let violation_to_json (v : Violation_record.t) : Yojson.Safe.t =
  `Assoc [
    ("tool_name", `String v.tool_name);
    ("violation_kind", `String (Violation_record.violation_kind_to_string v.violation_kind));
    ("effective_mode", `String (Agent_sdk.Execution_mode.to_string v.effective_mode));
  ]

let recommendation_to_json (r : mode_recommendation) : Yojson.Safe.t =
  `Assoc [
    ("current_mode", `String (Agent_sdk.Execution_mode.to_string r.current_mode));
    ("minimum_required", `String (Agent_sdk.Execution_mode.to_string r.minimum_required));
    ("gap", `Int r.gap);
    ("offending_tools", `List (List.map (fun s -> `String s) r.offending_tools));
    ("violation_kinds", `List (List.map (fun k ->
       `String (Violation_record.violation_kind_to_string k)) r.violation_kinds));
  ]

let to_json (r : eval_result) : Yojson.Safe.t =
  let base = [
    ("run_id", `String r.run_id);
    ("contract_id", `String r.contract_id);
    ("result_status",
     `String (Agent_sdk.Cdal_proof.show_result_status r.result_status));
    ("overall", severity_to_json r.overall);
    ("violations", `List (List.map violation_to_json r.evidence.violations));
    ("token_usage_total", `Int (Token_usage_record.total_tokens r.evidence.token_usage));
    ("tool_trace_count", `Int r.evidence.tool_trace_count);
    ("completed_normally", `Bool r.evidence.completed_normally);
    ("evaluated_at", `Float r.evaluated_at);
  ] in
  let extra = match r.recommendation with
    | Some rec_ -> [("recommendation", recommendation_to_json rec_)]
    | None -> []
  in
  `Assoc (base @ extra)

(* ================================================================ *)
(* JSONL persistence                                                 *)
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
