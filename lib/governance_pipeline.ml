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

type governance_decision = Governance_pipeline_types.governance_decision =
  { tool_name : string
  ; risk : risk_level
  ; action : [ `Allow | `Require_confirm of string | `Deny of string ]
  ; trace_id : string
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

let trace_id prefix =
  let entropy =
    Printf.sprintf "%s|%d|%.6f|%d"
      prefix (Unix.getpid ()) (Unix.gettimeofday ()) (Random.bits ())
  in
  let digest = Digestif.SHA256.(digest_string entropy |> to_hex) in
  prefix ^ "_" ^ String.sub digest 0 16

let generate_trace_id () =
  match Otel_spans.current_trace_id () with
  | Some otel_tid -> otel_tid
  | None -> trace_id "gov"
;;

(* ── Policy Decision ────────────────────────────────────────── *)

(** Minimum risk level that requires confirmation for each governance level.

    Security gate: unknown level (typo, future variant) is fail-CLOSED — it
    requires confirmation for [Critical] risk and warns the operator instead
    of silently allowing every tool through. Mirrors the fail-closed posture
    of [audit_threshold] just below. See #7641 / #8605. *)
let confirm_threshold governance_level =
  if Env_config_core.disable_hitl () then None
  else
    match governance_level with
    | "paranoid" -> Some Medium
    | "enterprise" -> Some High
    | "production" -> Some Critical
    | "development" -> None
    | other ->
      Log.Governance.warn
        "confirm_threshold: unknown governance_level %S -> fail-closed (require confirm at \
         Critical); see #7641"
        other;
      Some Critical
;;

let keeper_confirm_threshold governance_level =
  if Env_config_core.disable_hitl () then None
  else
    match governance_level with
    | "production" -> Some High
    | other -> confirm_threshold other
;;

let runtime_auto_approval_blocked = function
  | None -> false
  | Some (meta : Keeper_meta_contract.keeper_meta) ->
    Option.is_some meta.runtime.last_blocker
;;

(** PR-E (Plan v3 Leak 1): split the legacy [auto_approval_forbidden]
    into a "hard" component that always wins and a "soft" pattern
    component that a narrowly-scoped routine allowlist match is
    permitted to override.

    - Hard forbidden = the request is at Critical risk OR structured
      [runtime.last_blocker] is set.  Routine matchers must not
      bypass these — this is where real safety walls live.  The
      blocker [detail] is free-form UI/debug context, not a policy
      classifier.
    - Soft forbidden = the tool name or op string trips
      [destructive_tool_or_op] (a substring filter on "shell"/"git"
      plus a small list of bash/git ops).

    The legacy [auto_approval_forbidden] is kept below for any
    existing caller that wants the combined predicate. *)
let auto_approval_hard_forbidden ~risk meta =
  risk = Critical || runtime_auto_approval_blocked meta
;;

(** Minimum risk level that triggers audit logging. *)
let audit_threshold = function
  | "paranoid" | "enterprise" -> Some Low
  | "production" -> Some Medium
  | "development" -> Some High
  | _ -> Some High
;;

let decide ~governance_level ~tool_name ~input =
  let risk = assess_risk ~tool_name ~input in
  let trace_id = generate_trace_id () in
  let action =
    if Env_config_core.disable_hitl () && auto_approval_hard_forbidden ~risk None then
      `Require_confirm
        (Printf.sprintf
           "Governance (%s): %s risk tool %S requires confirmation: auto-approval is \
            hard-forbidden"
           governance_level
           (risk_level_to_string risk)
           tool_name)
    else
    match confirm_threshold governance_level with
    | Some threshold when risk_level_to_int risk >= risk_level_to_int threshold ->
      `Require_confirm
        (Printf.sprintf
           "Governance (%s): %s risk tool %S requires confirmation"
           governance_level
           (risk_level_to_string risk)
           tool_name)
    | _ -> `Allow
  in
  { tool_name; risk; action; trace_id }
;;

(* ── Audit Integration ──────────────────────────────────────── *)

let should_audit ~governance_level risk =
  match audit_threshold governance_level with
  | Some threshold -> risk_level_to_int risk >= risk_level_to_int threshold
  | None -> false
;;

let audit_decision (config : Workspace.config) (decision : governance_decision) =
  let audit_decision, action_str =
    match decision.action with
    | `Allow -> Audit_log.Governance_allow, "allow"
    | `Require_confirm _ -> Audit_log.Governance_require_confirm, "require_confirm"
    | `Deny _ -> Audit_log.Governance_deny, "deny"
  in
  Audit_log.log_governance_decision
    config
    ~agent_id:"governance-pipeline"
    ~trace_id:decision.trace_id
    ~decision:audit_decision
    ~action_type:(risk_level_to_string decision.risk)
    ~confirmation_state:action_str
    ()
;;

(* ── Auto-Petition for High/Critical Risk ──────────────────── *)

let maybe_create_petition ~config:_ ~(decision : governance_decision) =
  if risk_level_to_int decision.risk >= risk_level_to_int High
  then
    Log.Governance.info
      "high-risk tool=%s (petition skipped; governance petitions retired)"
      decision.tool_name
;;

(* ── Pre-Hook Construction ──────────────────────────────────── *)

let make_pre_hook ~config ~governance_level =
  fun ~name ~args ->
  let decision = decide ~governance_level ~tool_name:name ~input:args in
  if should_audit ~governance_level decision.risk then audit_decision config decision;
  match decision.action with
  | `Allow -> Tool_dispatch.Pass
  | `Require_confirm reason ->
    maybe_create_petition ~config ~decision;
    Log.Governance.info
      "[%s] tool=%s risk=%s -> require_confirm (trace=%s)"
      governance_level
      name
      (risk_level_to_string decision.risk)
      decision.trace_id;
    let response =
      `Assoc
        [ "status", `String "awaiting_approval"
        ; "trace_id", `String decision.trace_id
        ; "risk_level", `String (risk_level_to_string decision.risk)
        ; "governance_level", `String governance_level
        ; "reason", `String reason
        ; "tool_name", `String name
        ]
    in
    (* Require_confirm pauses for human approval — not a policy
       denial.  Stamp [Workflow_rejection] here so the same dispatch
       outcome produces the same failure-class bucket regardless of
       which boundary observes it. *)
    Tool_dispatch.Reject
      (Error
         { Tool_result.class_ = Tool_result.Workflow_rejection
         ; message = Yojson.Safe.to_string response
         ; data = response
         ; tool_name = name
         ; duration_ms = 0.0
         })
  | `Deny reason ->
    maybe_create_petition ~config ~decision;
    Log.Governance.warn
      "[%s] tool=%s risk=%s -> deny (trace=%s)"
      governance_level
      name
      (risk_level_to_string decision.risk)
      decision.trace_id;
    let response =
      `Assoc
        [ "status", `String "denied"
        ; "trace_id", `String decision.trace_id
        ; "risk_level", `String (risk_level_to_string decision.risk)
        ; "governance_level", `String governance_level
        ; "reason", `String reason
        ; "tool_name", `String name
        ]
    in
    (* Governance Reject — policy gate said no.  Stamp [Policy_rejection]
       so failure-class telemetry buckets governance denials separately
       from runtime/transient errors. *)
    Tool_dispatch.Reject
      (Error
         { Tool_result.class_ = Tool_result.Policy_rejection
         ; message = Yojson.Safe.to_string response
         ; data = response
         ; tool_name = name
         ; duration_ms = 0.0
         })
;;

(* ── Installation ───────────────────────────────────────────── *)

let install ~config ~governance_level =
  let hook = make_pre_hook ~config ~governance_level in
  Tool_dispatch.register_pre_hook hook;
  Log.Governance.info "pipeline installed: level=%s" governance_level
;;

(* ── OAS Approval Pipeline bridge (#5902) ─────────────────── *)

let selected_model_of_meta = function
  | None -> None
  | Some (_ : Keeper_meta_contract.keeper_meta) ->
    None
;;

let nonempty_trimmed value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed
;;

let input_op_opt input =
  Option.bind (Safe_ops.json_string_opt "op" input) nonempty_trimmed
;;

let destructive_tool_or_op ~tool_name ~input =
  let normalized_tool = String.lowercase_ascii tool_name in
  let normalized_op =
    input_op_opt input |> Option.map String.lowercase_ascii |> Option.value ~default:""
  in
  let destructive_ops =
    [ "bash"
    ; "git"
    ; "git_commit"
    ; "git_push"
    ; "git_push_force"
    ; "git_reset"
    ; "git_reset_hard"
    ; "git_rebase"
    ; "git_clean"
    ; "git_apply"
    ]
  in
  String_util.contains_substring_ci normalized_tool "shell"
  || String_util.contains_substring_ci normalized_tool "git"
  || List.mem normalized_op destructive_ops
;;

let auto_approval_forbidden ~tool_name ~input ~risk meta =
  risk = Critical
  || destructive_tool_or_op ~tool_name ~input
  || runtime_auto_approval_blocked meta
;;

let auto_approval_soft_forbidden ~tool_name ~input =
  destructive_tool_or_op ~tool_name ~input
;;

let to_oas_approval_callback ~config ~governance_level ~keeper_name ?meta ?clock ()
  : Agent_sdk.Hooks.approval_callback
  =
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
      |> List.map (fun (s : Masc_domain.tool_schema) -> s.name)
    in
    let trifecta_count, _, _, _ = assess_trifecta ~active_tool_names in
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
    let hard_forbidden = auto_approval_hard_forbidden ~risk meta in
    let soft_forbidden = auto_approval_soft_forbidden ~tool_name ~input in
    let hitl_disabled = Env_config_core.disable_hitl () in
    let auto_approval_forbidden = hard_forbidden || (not hitl_disabled && soft_forbidden) in
    if hitl_disabled && soft_forbidden then
      Log.Governance.warn "[%s] HITL bypass: soft_forbidden tool=%s allowed via disable_hitl"
        keeper_name tool_name;
    let requires_operator_approval = needs_approval || auto_approval_forbidden in
    if trifecta_active
    then
      Log.Governance.debug
        "[%s] trifecta_active tool=%s base=%s effective=%s needs_approval=%b \
         requires_operator_approval=%b"
        keeper_name
        tool_name
        (risk_level_to_string base_risk)
        (risk_level_to_string risk)
        needs_approval
        requires_operator_approval;
    if trifecta_active && risk_level_to_int risk > risk_level_to_int base_risk
    then
      Log.Governance.warn
        "[%s] trifecta escalated tool=%s base=%s effective=%s"
        keeper_name
        tool_name
        (risk_level_to_string base_risk)
        (risk_level_to_string risk);
    if requires_operator_approval
    then (
      let turn_id =
        Option.map
          (fun (meta : Keeper_meta_contract.keeper_meta) -> meta.runtime.usage.total_turns + 1)
          meta
      in
      let task_id =
        Option.bind meta (fun keeper_meta ->
          Keeper_runtime_contract.current_task_id_opt keeper_meta)
      in
      let goal_id =
        Option.bind meta (fun keeper_meta ->
          Keeper_runtime_contract.primary_goal_id_opt keeper_meta)
      in
      let goal_ids =
        Option.map
          (fun (keeper_meta : Keeper_meta_contract.keeper_meta) -> keeper_meta.active_goal_ids)
          meta
      in
      let runtime_contract =
        Option.map
          (fun keeper_meta ->
             Keeper_runtime_contract.runtime_contract_json ~config keeper_meta)
          meta
      in
      let sandbox_profile, backend, sandbox_target =
        match meta with
        | Some keeper_meta ->
          let backend = Keeper_runtime_contract.backend_of_meta keeper_meta in
          ( Some (Keeper_types_profile.sandbox_profile_to_string keeper_meta.sandbox_profile)
          , Some backend
          , Some backend )
        | None -> None, None, None
      in
      let selected_model = selected_model_of_meta meta in
      let risk_level = queue_risk_level risk in
      let base_path = (config : Workspace.config).base_path in
      let always_approve =
        Option.bind meta (fun (m : Keeper_meta_contract.keeper_meta) -> m.always_approve)
        |> Option.value ~default:false
      in
      let rule_match =
        if auto_approval_forbidden
        then None
        else
          Keeper_approval_queue.find_matching_rule
            ~base_path
            ~keeper_name
            ~tool_name
            ~input
            ~risk_level
            ?sandbox_profile
            ?backend
            ?runtime_contract
            ()
      in
      if (not auto_approval_forbidden) && always_approve
      then (
        Keeper_approval_queue.audit_approval_event
          ~base_path
          ~event_type:"auto_approved_always"
          ~id:(Printf.sprintf "auto_always_%s_%s" keeper_name tool_name)
          ~keeper_name
          ~tool_name
          ~risk_level
          ?turn_id
          ?task_id
          ?goal_id
          ~goal_ids:(Option.value ~default:[] goal_ids)
          ?sandbox_target
          ?runtime_contract
          ?selected_model
          ~disposition:"Pass"
          ~disposition_reason:"always_approve_enabled"
          ~auto_approved:true
          ();
        Agent_sdk.Hooks.Approve)
      else (
        match rule_match with
           | Some matched ->
             Keeper_approval_queue.audit_approval_event
               ~base_path
               ~event_type:"auto_approved_rule_match"
               ~id:(Printf.sprintf "auto_%s_%s" keeper_name matched.rule_id)
               ~keeper_name
               ~tool_name
               ~risk_level
               ?turn_id
               ?task_id
               ?goal_id
               ~goal_ids:(Option.value ~default:[] goal_ids)
               ?sandbox_target
               ?runtime_contract
               ?selected_model
               ~disposition:"Pass"
               ~disposition_reason:"healthy"
               ~rule_match:matched
               ~auto_approved:true
               ();
             Agent_sdk.Hooks.Approve
           | None ->
             Keeper_approval_queue.submit_and_await
               ~keeper_name
               ~tool_name
               ~input
               ~base_path
               ?turn_id
               ?task_id
               ?goal_id
               ?goal_ids
               ?sandbox_target
               ?sandbox_profile
               ?backend
               ?runtime_contract
               ?selected_model
               ~disposition:"Blocked"
               ~disposition_reason:"waiting_approval"
               ~risk_level
               ?clock
               ()))
    else Agent_sdk.Hooks.Approve
;;
