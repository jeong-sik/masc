(** Governance_pipeline — Unified risk-based approval gate for tool dispatch.

    Classifies tool calls by risk level and enforces governance policy as a
    Tool_dispatch pre_hook. Short-circuits denied or confirm-required calls
    before the handler runs.

    @since 2.128.0 *)

type risk_level = Governance_pipeline_types.risk_level =
  | Low
  | Medium
  | High
  | Critical

type governance_decision = Governance_pipeline_types.governance_decision = {
  tool_name : string;
  risk : risk_level;
  action : [ `Allow | `Require_confirm of string | `Deny of string ];
  trace_id : string;
}

type capability_class = Governance_pipeline_types.capability_class =
  | External_input
  | Sensitive_access
  | State_modification

let risk_level_to_string = Governance_pipeline_types.risk_level_to_string
let risk_level_to_int = Governance_pipeline_types.risk_level_to_int
let tool_capabilities = Governance_pipeline_risk.tool_capabilities
let assess_trifecta = Governance_pipeline_risk.assess_trifecta
let combinatorial_risk_escalation = Governance_pipeline_risk.combinatorial_risk_escalation
let assess_risk = Governance_pipeline_risk.assess_risk

(* ── Trace ID generation ────────────────────────────────────── *)

let generate_trace_id () =
  match Otel_spans.current_trace_id () with
  | Some otel_tid -> otel_tid
  | None -> Operator_pending_confirm.trace_id "gov"

(* ── Policy Decision ────────────────────────────────────────── *)

(** Minimum risk level that requires confirmation for each governance level.

    Security gate: unknown level (typo, future variant) is fail-CLOSED — it
    requires confirmation for [Critical] risk and warns the operator instead
    of silently allowing every tool through. Mirrors the fail-closed posture
    of [audit_threshold] just below. See #7641 / #8605. *)
let confirm_threshold = function
  | "paranoid" -> Some Medium
  | "enterprise" -> Some High
  | "production" -> Some Critical
  | "development" -> None
  | other ->
      Log.Governance.warn
        "confirm_threshold: unknown governance_level %S -> fail-closed (require confirm at Critical); see #7641"
        other;
      Some Critical

let keeper_confirm_threshold = function
  | "production" -> Some High
  | other -> confirm_threshold other

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

let audit_decision (config : Coord.config) (decision : governance_decision) =
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

let maybe_create_petition ~config:_ ~(decision : governance_decision) =
  if risk_level_to_int decision.risk >= risk_level_to_int High then
    Log.Governance.info "high-risk tool=%s (petition skipped; governance petitions retired)"
      decision.tool_name

(* ── Pre-Hook Construction ──────────────────────────────────── *)

let make_pre_hook ~config ~governance_level =
  fun ~name ~args ->
    let decision = decide ~governance_level ~tool_name:name ~input:args in
    if should_audit ~governance_level decision.risk then
      audit_decision config decision;
    match decision.action with
    | `Allow -> Tool_dispatch.Pass
    | `Require_confirm reason ->
        maybe_create_petition ~config ~decision;
        Log.Governance.info "[%s] tool=%s risk=%s -> require_confirm (trace=%s)"
          governance_level name (risk_level_to_string decision.risk) decision.trace_id;
        let response =
          `Assoc
            [
              ("status", `String "awaiting_approval");
              ("trace_id", `String decision.trace_id);
              ("risk_level", `String (risk_level_to_string decision.risk));
              ("governance_level", `String governance_level);
              ("reason", `String reason);
              ("tool_name", `String name);
            ]
        in
        Tool_dispatch.Reject {
          Tool_result.success = false;
          data = response;
          tool_name = name;
          duration_ms = 0.0;
        }
    | `Deny reason ->
        maybe_create_petition ~config ~decision;
        Log.Governance.warn "[%s] tool=%s risk=%s -> deny (trace=%s)"
          governance_level name (risk_level_to_string decision.risk) decision.trace_id;
        let response =
          `Assoc
            [
              ("status", `String "denied");
              ("trace_id", `String decision.trace_id);
              ("risk_level", `String (risk_level_to_string decision.risk));
              ("governance_level", `String governance_level);
              ("reason", `String reason);
              ("tool_name", `String name);
            ]
        in
        Tool_dispatch.Reject {
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

(* ── OAS Approval Pipeline bridge (#5902) ─────────────────── *)

let to_oas_approval_callback
    ~governance_level ~keeper_name : Oas.Hooks.approval_callback =
  let queue_risk_level = function
    | Low -> Keeper_approval_queue.Low
    | Medium -> Keeper_approval_queue.Medium
    | High -> Keeper_approval_queue.High
    | Critical -> Keeper_approval_queue.Critical
  in
  fun ~tool_name ~input ->
    let active_tool_names =
      Tool_shard.get_agent_shards keeper_name
      |> Tool_shard.tools_of_shards
      |> List.map (fun (s : Types.tool_schema) -> s.name)
    in
    let (trifecta_count, _, _, _) = assess_trifecta ~active_tool_names in
    let trifecta_active = trifecta_count >= 3 in
    let base_risk = assess_risk ~tool_name ~input in
    let risk =
      combinatorial_risk_escalation ~trifecta_active ~tool_name ~input ~base_risk
    in
    let needs_approval =
      match keeper_confirm_threshold governance_level with
      | Some threshold -> risk_level_to_int risk >= risk_level_to_int threshold
      | None -> false
    in
    if trifecta_active then
      Log.Governance.debug
        "[%s] trifecta_active tool=%s base=%s effective=%s needs_approval=%b"
        keeper_name tool_name
        (risk_level_to_string base_risk)
        (risk_level_to_string risk)
        needs_approval;
    if trifecta_active
       && risk_level_to_int risk > risk_level_to_int base_risk
    then
      Log.Governance.warn
        "[%s] trifecta escalated tool=%s base=%s effective=%s"
        keeper_name tool_name
        (risk_level_to_string base_risk)
        (risk_level_to_string risk);
    if needs_approval then
      Keeper_approval_queue.submit_and_await
        ~keeper_name
        ~tool_name
        ~input
        ~risk_level:(queue_risk_level risk)
    else
      Oas.Hooks.Approve
