(** Governance_pipeline — Unified risk-based approval gate for tool dispatch.

    Classifies tool calls by risk level and enforces governance policy as a
    Tool_dispatch pre_hook. Short-circuits denied or confirm-required calls
    before the handler runs.

    @since 2.128.0 *)

(* ── Types ──────────────────────────────────────────────────── *)

type risk_level =
  | Low
  | Medium
  | High
  | Critical

type governance_decision = {
  tool_name : string;
  risk : risk_level;
  action : [ `Allow | `Require_confirm of string | `Deny of string ];
  trace_id : string;
}

let risk_level_to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Critical -> "critical"

let risk_level_to_int = function
  | Low -> 0
  | Medium -> 1
  | High -> 2
  | Critical -> 3

(* ── Risk Assessment ────────────────────────────────────────── *)

(** Pattern sets for risk classification.
    Each pattern is checked against the tool name (case-insensitive substring). *)

(** Explicit per-tool risk overrides.
    Checked BEFORE pattern matching. Use this to correct misclassifications
    caused by substring matching (e.g. "query_skill" matching "kill"). *)
let risk_overrides : (string * risk_level) list = [
  (* False positives from pattern matching *)
  ("masc_a2a_query_skill", Low);       (* "skill" contains "kill" substring *)
  ("masc_keeper_tool_catalog", Low);   (* "catalog" is read-only *)
  ("masc_model_catalog", Low);         (* read-only *)
  (* Explicit claim surfaces. *)
  ("masc_claim_next", Medium);
  ("masc_claim_task", Medium);
]

let critical_patterns =
  [ "delete"; "remove"; "drop"; "force"; "reset"; "kill"; "destroy"; "purge" ]

let high_patterns =
  [ "create"; "update"; "write"; "deploy"; "push"; "merge"; "set"; "send";
    "inject"; "spawn"; "modify"; "assign" ]

let medium_patterns =
  [ "claim"; "join"; "leave"; "start"; "stop"; "pause"; "resume";
    "confirm"; "approve"; "reject"; "cancel" ]

let contains_pattern name patterns =
  let name_lc = String.lowercase_ascii name in
  List.exists (fun pat ->
    let pat_len = String.length pat in
    let name_len = String.length name_lc in
    if pat_len > name_len then false
    else
      let rec check i =
        if i + pat_len > name_len then false
        else if String.sub name_lc i pat_len = pat then true
        else check (i + 1)
      in
      check 0
  ) patterns

let classify_name name =
  if contains_pattern name critical_patterns then Critical
  else if contains_pattern name high_patterns then High
  else if contains_pattern name medium_patterns then Medium
  else Low

let transition_action input =
  match input with
  | `Assoc kvs ->
      (match List.assoc_opt "action" kvs with
       | Some (`String action) ->
           let trimmed = String.trim action in
           if trimmed = "" then None else Some (String.lowercase_ascii trimmed)
       | _ -> None)
  | _ -> None

let assess_risk ~tool_name ~input =
  (* Check explicit overrides first *)
  match List.assoc_opt tool_name risk_overrides with
  | Some level -> level
  | None ->
      if String.equal tool_name "masc_transition" then
        match transition_action input with
        | Some action -> classify_name action
        | None -> Low
      else
        classify_name tool_name

(* ── Trace ID generation ────────────────────────────────────── *)

let generate_trace_id () =
  match Otel_spans.current_trace_id () with
  | Some otel_tid -> otel_tid
  | None -> Operator_pending_confirm.trace_id "gov"

(* ── Policy Decision ────────────────────────────────────────── *)

(** Minimum risk level that requires confirmation for each governance level. *)
let confirm_threshold = function
  | "paranoid" -> Some Medium
  | "enterprise" -> Some High
  | "production" -> Some Critical
  | "development" | _ -> None

(** Minimum risk level that triggers audit logging. *)
let audit_threshold = function
  | "paranoid" | "enterprise" -> Some Low
  | "production" -> Some Medium
  | "development" -> Some High
  | _ -> Some High

let decide ~governance_level ~tool_name ~input =
  let risk = assess_risk ~tool_name ~input in
  let trace_id = generate_trace_id () in
  let action =
    match confirm_threshold governance_level with
    | Some threshold when risk_level_to_int risk >= risk_level_to_int threshold ->
        `Require_confirm
          (Printf.sprintf
             "Governance (%s): %s risk tool %S requires confirmation"
             governance_level (risk_level_to_string risk) tool_name)
    | _ -> `Allow
  in
  { tool_name; risk; action; trace_id }

(* ── Audit Integration ──────────────────────────────────────── *)

let should_audit ~governance_level risk =
  match audit_threshold governance_level with
  | Some threshold -> risk_level_to_int risk >= risk_level_to_int threshold
  | None -> false

let audit_decision (config : Room.config) (decision : governance_decision) =
  let action_str =
    match decision.action with
    | `Allow -> "allow"
    | `Require_confirm _ -> "require_confirm"
    | `Deny _ -> "deny"
  in
  Audit_log.log_governance_decision config
    ~agent_id:"governance-pipeline"
    ~trace_id:decision.trace_id
    ~decision:action_str
    ~action_type:(risk_level_to_string decision.risk)
    ~confirmation_state:action_str
    ()

(* ── Auto-Petition for High/Critical Risk ──────────────────── *)

let maybe_create_petition ~config ~(decision : governance_decision) =
  if risk_level_to_int decision.risk >= risk_level_to_int High then begin
    let module GV2 = Council.Governance_v2 in
    let gv2_risk = if decision.risk = Critical then GV2.High else GV2.Low in
    let action : GV2.action_request = {
      action_type = "review_tool_usage";
      target_type = Some "tool";
      target_id = Some decision.tool_name;
      payload = Some (`Assoc [
        ("risk_level", `String (risk_level_to_string decision.risk));
        ("trace_id", `String decision.trace_id);
      ]);
    } in
    match GV2.submit_petition config.Room.base_path
      ~title:(Printf.sprintf "High-risk tool: %s" decision.tool_name)
      ~origin:"governance-pipeline"
      ~subject_type:"tool_call"
      ~risk_class:gv2_risk
      ~requested_action:(Some action)
      ~source_refs:[decision.trace_id]
      ~created_by:"governance-pipeline"
    with
    | Ok result ->
      Log.Governance.info "auto-petition created: case=%s tool=%s"
        result.case_.id decision.tool_name
    | Error msg ->
      Log.Governance.warn "auto-petition failed: %s" msg
  end

(* ── Pre-Hook Construction ──────────────────────────────────── *)

let make_pre_hook ~config ~governance_level =
  fun ~name ~args ->
    let decision = decide ~governance_level ~tool_name:name ~input:args in
    (* Audit if policy requires it *)
    if should_audit ~governance_level decision.risk then
      audit_decision config decision;
    match decision.action with
    | `Allow -> None  (* proceed to handler *)
    | `Require_confirm reason ->
        maybe_create_petition ~config ~decision;
        Log.Governance.info "[%s] tool=%s risk=%s -> require_confirm (trace=%s)"
          governance_level name (risk_level_to_string decision.risk) decision.trace_id;
        let response = `Assoc [
          ("status", `String "awaiting_approval");
          ("trace_id", `String decision.trace_id);
          ("risk_level", `String (risk_level_to_string decision.risk));
          ("governance_level", `String governance_level);
          ("reason", `String reason);
          ("tool_name", `String name);
        ] in
        Some {
          Tool_result.success = false;
          data = response;
          tool_name = name;
          duration_ms = 0.0;
        }
    | `Deny reason ->
        maybe_create_petition ~config ~decision;
        Log.Governance.warn "[%s] tool=%s risk=%s -> deny (trace=%s)"
          governance_level name (risk_level_to_string decision.risk) decision.trace_id;
        let response = `Assoc [
          ("status", `String "denied");
          ("trace_id", `String decision.trace_id);
          ("risk_level", `String (risk_level_to_string decision.risk));
          ("governance_level", `String governance_level);
          ("reason", `String reason);
          ("tool_name", `String name);
        ] in
        Some {
          Tool_result.success = false;
          data = response;
          tool_name = name;
          duration_ms = 0.0;
        }

(* ── Installation ───────────────────────────────────────────── *)

let install ~config ~governance_level =
  let hook = make_pre_hook ~config ~governance_level in
  Tool_dispatch.register_pre_hook hook;
  Log.Governance.info "pipeline installed: level=%s" governance_level
