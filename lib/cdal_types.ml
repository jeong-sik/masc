(** Cdal_types -- Typed CDAL verdict and check-result types.

    @since CDAL Phase 1A *)

(* ================================================================ *)
(* Core types                                                        *)
(* ================================================================ *)

type contract_status =
  | Satisfied
  | Violated
  | Inconclusive

type completeness_impact =
  | Blocks_verdict
  | Annotation_only

type contract_finding = {
  check_id : string;
  event_id : string option;
  observed : Yojson.Safe.t;
  expected : Yojson.Safe.t;
  trace_ref : string option;
}

type completeness_gap = {
  artifact : string;
  reason : string;
  impact : completeness_impact;
}

type check_result = {
  check_id : string;
  status : contract_status;
  findings : contract_finding list;
  completeness_gaps : completeness_gap list;
}

type contract_verdict = {
  run_id : string;
  contract_id : string;
  claim_scope : string;
  judgment_basis_hash : string;
  judgment_hash : string;
  loader_semantics_version : string;
  schema_compat_mode : string;
  status : contract_status;
  findings : contract_finding list;
  completeness_gaps : completeness_gap list;
  check_results : check_result list;
}

(* ================================================================ *)
(* Constants                                                         *)
(* ================================================================ *)

let claim_scope_phase1 = "phase1_scoped_runtime_audit"
let loader_semantics_version_phase1 = "phase1a_v1"
let schema_compat_mode_v1 = "proof_bundle_v1"

(* ================================================================ *)
(* String conversions                                                *)
(* ================================================================ *)

let contract_status_to_string = function
  | Satisfied -> "satisfied"
  | Violated -> "violated"
  | Inconclusive -> "inconclusive"

let contract_status_of_string = function
  | "satisfied" -> Ok Satisfied
  | "violated" -> Ok Violated
  | "inconclusive" -> Ok Inconclusive
  | s -> Error (Printf.sprintf "unknown contract_status: %s" s)

let completeness_impact_to_string = function
  | Blocks_verdict -> "blocks_verdict"
  | Annotation_only -> "annotation_only"

let completeness_impact_of_string = function
  | "blocks_verdict" -> Ok Blocks_verdict
  | "annotation_only" -> Ok Annotation_only
  | s -> Error (Printf.sprintf "unknown completeness_impact: %s" s)

(* ================================================================ *)
(* JSON helpers                                                      *)
(* ================================================================ *)

let string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String s) -> Ok s
  | Some j -> Error (Printf.sprintf "%s: expected string, got %s" key
                       (Yojson.Safe.to_string j))
  | None -> Error (Printf.sprintf "missing field: %s" key)

let string_option_field key fields =
  match List.assoc_opt key fields with
  | Some (`String s) -> Ok (Some s)
  | Some `Null | None -> Ok None
  | Some j -> Error (Printf.sprintf "%s: expected string or null, got %s" key
                       (Yojson.Safe.to_string j))

let json_field key fields =
  match List.assoc_opt key fields with
  | Some v -> Ok v
  | None -> Error (Printf.sprintf "missing field: %s" key)

let list_field key of_item fields =
  match List.assoc_opt key fields with
  | Some (`List items) ->
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | x :: rest ->
        (match of_item x with
         | Ok v -> go (v :: acc) rest
         | Error e -> Error (Printf.sprintf "%s[]: %s" key e))
    in
    go [] items
  | Some j -> Error (Printf.sprintf "%s: expected list, got %s" key
                       (Yojson.Safe.to_string j))
  | None -> Ok []

let option_to_json f = function
  | Some v -> f v
  | None -> `Null

(* ================================================================ *)
(* contract_finding JSON                                             *)
(* ================================================================ *)

let contract_finding_to_json (f : contract_finding) : Yojson.Safe.t =
  Yojson.Safe.sort (`Assoc [
    ("check_id", `String f.check_id);
    ("event_id", option_to_json (fun s -> `String s) f.event_id);
    ("expected", f.expected);
    ("observed", f.observed);
    ("trace_ref", option_to_json (fun s -> `String s) f.trace_ref);
  ])

let contract_finding_of_json = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* check_id = string_field "check_id" fields in
    let* event_id = string_option_field "event_id" fields in
    let* observed = json_field "observed" fields in
    let* expected = json_field "expected" fields in
    let* trace_ref = string_option_field "trace_ref" fields in
    Ok { check_id; event_id; observed; expected; trace_ref }
  | j -> Error (Printf.sprintf "contract_finding: expected object, got %s"
                  (Yojson.Safe.to_string j))

(* ================================================================ *)
(* completeness_gap JSON                                             *)
(* ================================================================ *)

let completeness_gap_to_json (g : completeness_gap) : Yojson.Safe.t =
  Yojson.Safe.sort (`Assoc [
    ("artifact", `String g.artifact);
    ("impact", `String (completeness_impact_to_string g.impact));
    ("reason", `String g.reason);
  ])

let completeness_gap_of_json = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* artifact = string_field "artifact" fields in
    let* reason = string_field "reason" fields in
    let* impact_str = string_field "impact" fields in
    let* impact = completeness_impact_of_string impact_str in
    Ok { artifact; reason; impact }
  | j -> Error (Printf.sprintf "completeness_gap: expected object, got %s"
                  (Yojson.Safe.to_string j))

(* ================================================================ *)
(* check_result JSON                                                 *)
(* ================================================================ *)

let check_result_to_json (r : check_result) : Yojson.Safe.t =
  Yojson.Safe.sort (`Assoc [
    ("check_id", `String r.check_id);
    ("completeness_gaps",
     `List (List.map completeness_gap_to_json r.completeness_gaps));
    ("findings", `List (List.map contract_finding_to_json r.findings));
    ("status", `String (contract_status_to_string r.status));
  ])

let check_result_of_json = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* check_id = string_field "check_id" fields in
    let* status_str = string_field "status" fields in
    let* status = contract_status_of_string status_str in
    let* findings = list_field "findings" contract_finding_of_json fields in
    let* completeness_gaps =
      list_field "completeness_gaps" completeness_gap_of_json fields in
    Ok { check_id; status; findings; completeness_gaps }
  | j -> Error (Printf.sprintf "check_result: expected object, got %s"
                  (Yojson.Safe.to_string j))

(* ================================================================ *)
(* contract_verdict JSON                                             *)
(* ================================================================ *)

let contract_verdict_to_json (v : contract_verdict) : Yojson.Safe.t =
  Yojson.Safe.sort (`Assoc [
    ("check_results", `List (List.map check_result_to_json v.check_results));
    ("claim_scope", `String v.claim_scope);
    ("completeness_gaps",
     `List (List.map completeness_gap_to_json v.completeness_gaps));
    ("contract_id", `String v.contract_id);
    ("findings", `List (List.map contract_finding_to_json v.findings));
    ("judgment_basis_hash", `String v.judgment_basis_hash);
    ("judgment_hash", `String v.judgment_hash);
    ("loader_semantics_version", `String v.loader_semantics_version);
    ("run_id", `String v.run_id);
    ("schema_compat_mode", `String v.schema_compat_mode);
    ("status", `String (contract_status_to_string v.status));
  ])

let contract_verdict_of_json = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* run_id = string_field "run_id" fields in
    let* contract_id = string_field "contract_id" fields in
    let* claim_scope = string_field "claim_scope" fields in
    let* judgment_basis_hash = string_field "judgment_basis_hash" fields in
    let* judgment_hash = string_field "judgment_hash" fields in
    let* loader_semantics_version =
      string_field "loader_semantics_version" fields in
    let* schema_compat_mode = string_field "schema_compat_mode" fields in
    let* status_str = string_field "status" fields in
    let* status = contract_status_of_string status_str in
    let* findings = list_field "findings" contract_finding_of_json fields in
    let* completeness_gaps =
      list_field "completeness_gaps" completeness_gap_of_json fields in
    let* check_results =
      list_field "check_results" check_result_of_json fields in
    Ok {
      run_id; contract_id; claim_scope;
      judgment_basis_hash; judgment_hash;
      loader_semantics_version; schema_compat_mode;
      status; findings; completeness_gaps; check_results;
    }
  | j -> Error (Printf.sprintf "contract_verdict: expected object, got %s"
                  (Yojson.Safe.to_string j))

(* ================================================================ *)
(* Judgment hash                                                     *)
(* ================================================================ *)

let compute_judgment_hash (v : contract_verdict) : string =
  let zeroed = { v with judgment_hash = "" } in
  let canonical =
    zeroed
    |> contract_verdict_to_json
    (* contract_verdict_to_json already sorts all keys recursively *)
    |> Yojson.Safe.to_string
  in
  let hash = Digest.string canonical |> Digest.to_hex in
  "md5:" ^ hash

(* ================================================================ *)
(* Persisted verdict envelope — typed wrapper for JSONL entries     *)
(* Issue #7551: replaces the prior `_task_id` string-prefix hack    *)
(* with a proper nested structure.                                   *)
(* ================================================================ *)

type persisted_verdict = {
  task_id : string option;
  verdict : contract_verdict;
}

let persisted_verdict_to_json pv =
  let base = [("verdict", contract_verdict_to_json pv.verdict)] in
  let fields = match pv.task_id with
    | Some tid -> ("task_id", `String tid) :: base
    | None -> base
  in
  `Assoc fields

let persisted_verdict_of_json = function
  | `Assoc fields ->
    (* New format: {"task_id": "...", "verdict": {...}} *)
    (match List.assoc_opt "verdict" fields with
     | Some verdict_json ->
       (match contract_verdict_of_json verdict_json with
        | Ok verdict ->
          let task_id = match List.assoc_opt "task_id" fields with
            | Some (`String s) -> Some s
            | _ -> None
          in
          Ok { task_id; verdict }
        | Error e -> Error e)
     | None ->
       (* Legacy format: flat verdict fields + optional "_task_id" prefix *)
       let task_id = match List.assoc_opt "_task_id" fields with
         | Some (`String s) -> Some s
         | _ -> None
       in
       let verdict_fields = List.filter (fun (k, _) -> k <> "_task_id") fields in
       (match contract_verdict_of_json (`Assoc verdict_fields) with
        | Ok verdict -> Ok { task_id; verdict }
        | Error e -> Error e))
  | other -> Error (Printf.sprintf "expected JSON object for persisted_verdict, got: %s"
                      (Yojson.Safe.to_string other))
