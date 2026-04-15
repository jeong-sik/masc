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

let max_risk_level left right =
  if risk_level_to_int left >= risk_level_to_int right then left else right

let _risk_level_of_contract_risk = function
  | Agent_sdk.Risk_class.Low -> Low
  | Agent_sdk.Risk_class.Medium -> Medium
  | Agent_sdk.Risk_class.High -> High
  | Agent_sdk.Risk_class.Critical -> Critical

(* ── Lethal Trifecta — Combinatorial Risk Assessment ─────────
   Simon Willison's "Lethal Trifecta": an agent simultaneously holding
   (1) untrusted external input, (2) sensitive data access, and
   (3) state modification capability = security incident.

   Meta AI's "Rule of Two": restrict to max 2 of 3 simultaneously.
   When all 3 are present, escalate state_modification tool risk.

   Classification is in code (not TOML) for the same reason as risk
   patterns: security policy changes require code review. *)

type capability_class =
  | External_input      (** Receives data from untrusted external sources *)
  | Sensitive_access    (** Can read potentially sensitive data *)
  | State_modification  (** Can modify system state *)

(** Per-tool capability classification.
    A tool may belong to multiple classes (e.g. keeper_bash spans all 3). *)
let capability_classification : (string * capability_class list) list = [
  (* External input sources *)
  ("masc_web_search",          [External_input]);
  ("masc_web_fetch",           [External_input]);
  (* Shell can curl/wget external data AND read secrets AND execute *)
  ("keeper_bash",              [External_input; Sensitive_access; State_modification]);
  ("keeper_shell",    [External_input; Sensitive_access]);
  (* Sensitive data access *)
  ("keeper_fs_read",           [Sensitive_access]);
  ("keeper_memory_search",     [Sensitive_access]);
  ("keeper_library_search",    [Sensitive_access]);
  ("keeper_library_read",      [Sensitive_access]);
  (* State modification *)
  ("keeper_fs_edit",           [State_modification]);
  ("keeper_pr_submit",         [State_modification]);
  ("keeper_pr_workflow",       [State_modification]);
]

let tool_capabilities name =
  match List.assoc_opt name capability_classification with
  | Some caps -> caps
  | None -> []

let has_capability cls caps =
  List.mem cls caps

(** Compute trifecta status from a set of active tool names.
    Returns (class_count, has_external, has_sensitive, has_state_mod). *)
let assess_trifecta ~active_tool_names =
  let has_ext = ref false in
  let has_sens = ref false in
  let has_mod = ref false in
  List.iter (fun name ->
    let caps = tool_capabilities name in
    if has_capability External_input caps then has_ext := true;
    if has_capability Sensitive_access caps then has_sens := true;
    if has_capability State_modification caps then has_mod := true;
  ) active_tool_names;
  let count =
    (if !has_ext then 1 else 0)
    + (if !has_sens then 1 else 0)
    + (if !has_mod then 1 else 0)
  in
  (count, !has_ext, !has_sens, !has_mod)

(** When trifecta is active (all 3 classes present), escalate risk
    of state_modification tools to at least High.
    This ensures HITL gates fire at lower governance levels. *)
let combinatorial_risk_escalation ~trifecta_active ~tool_name ~base_risk ~input =
  if trifecta_active then
    let caps = tool_capabilities tool_name in
    let read_only_shell_gh =
      String.equal tool_name "keeper_shell"
      && Keeper_tool_registry.is_read_only_with_input ~tool_name ~input
    in
    if has_capability State_modification caps && not read_only_shell_gh then
      max_risk_level base_risk High
    else
      base_risk
  else
    base_risk

(* ── Risk Assessment ────────────────────────────────────────── *)

(** {2 Risk pattern sets — security-critical SSOT}

    Each pattern is checked against the tool name (case-insensitive substring).
    These are intentionally in code (not TOML) because changing risk
    classification is a security policy change that requires code review.
    Governance LEVEL (development/production/enterprise/paranoid) is the
    configurable dial — see [MASC_GOVERNANCE_LEVEL] env var. *)

(** Explicit per-tool risk overrides.
    Checked BEFORE pattern matching. Use this to correct misclassifications
    caused by substring matching (e.g. "query_skill" matching "kill"). *)
let risk_overrides : (string * risk_level) list = [
  (* False positives from pattern matching *)
  ("masc_a2a_query_skill", Low);       (* "skill" contains "kill" substring *)
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

let overwrite_sensitive_tools =
  [
    "masc_code_write";
    "masc_code_edit";
    "keeper_fs_edit";
    "keeper_write";
    "edit_text_file";
  ]

let empty_overwrite_payload_keys = [ "content"; "new_string" ]

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

let rec collect_string_values ~keys json =
  match json with
  | `Assoc kvs ->
      List.concat_map
        (fun (key, value) ->
          let normalized_key = String.lowercase_ascii (String.trim key) in
          let direct =
            if List.mem normalized_key keys then
              match value with
              | `String text -> [ text ]
              | _ -> []
            else
              []
          in
          direct @ collect_string_values ~keys value)
        kvs
  | `List values -> List.concat_map (collect_string_values ~keys) values
  | _ -> []

let rec collect_all_string_values json =
  match json with
  | `Assoc kvs ->
      List.concat_map (fun (_, value) -> collect_all_string_values value) kvs
  | `List values -> List.concat_map collect_all_string_values values
  | `String text -> [ text ]
  | _ -> []

let rec collect_string_list_values ~keys json =
  match json with
  | `Assoc kvs ->
      List.concat_map
        (fun (key, value) ->
          let normalized_key = String.lowercase_ascii (String.trim key) in
          let direct =
            if List.mem normalized_key keys then
              match value with
              | `List values ->
                  values
                  |> List.filter_map (function
                         | `String text ->
                             let trimmed = String.trim text in
                             if trimmed = "" then None else Some trimmed
                         | _ -> None)
              | _ -> []
            else
              []
          in
          direct @ collect_string_list_values ~keys value)
        kvs
  | `List values -> List.concat_map (collect_string_list_values ~keys) values
  | _ -> []

let has_destructive_payload input =
  collect_all_string_values input
  |> List.exists (fun text -> Eval_gate.detect_destructive text <> None)

let has_empty_overwrite_payload input =
  collect_string_values ~keys:empty_overwrite_payload_keys input
  |> List.exists (fun text -> String.trim text = "")

let _tool_names_of_input ~tool_name input =
  let (_ : string) = tool_name in
  collect_string_list_values ~keys:[ "tool_names" ] input
  |> List.sort_uniq String.compare

let classify_with_contract_risk ~tool_name:_ ~input:_ =
  (* Contract_risk removed *)
  None

let classify_with_metadata ~tool_name =
  let meta = Tool_catalog.metadata tool_name in
  match (meta.Tool_catalog.destructive, meta.Tool_catalog.readonly) with
  | Some true, _ -> Some Critical
  | _, Some true -> Some Low
  | _ -> None

let classify_with_payload ~tool_name ~input =
  if has_destructive_payload input then Some Critical
  else if List.mem tool_name overwrite_sensitive_tools && has_empty_overwrite_payload input
  then Some Critical
  else None

let baseline_risk ~tool_name ~input =
  match classify_with_metadata ~tool_name with
  | Some level -> level
  | None -> (
      match List.assoc_opt tool_name risk_overrides with
      | Some level -> level
      | None ->
          if String.equal tool_name "masc_transition" then
            match transition_action input with
            | Some action -> classify_name action
            | None -> Low
          else
            classify_name tool_name)

let keeper_mutation_requires_high_floor ~tool_name ~input =
  match tool_name with
  | "keeper_fs_edit" | "keeper_write"
  | "keeper_pr_submit" | "keeper_pr_workflow" -> true
  | "keeper_shell" ->
    (* keeper_shell is mutating only when op=gh AND the gh command mutates *)
    Keeper_tool_registry.is_shell_gh_op input
    && not (Keeper_tool_registry.is_read_only_with_input ~tool_name ~input)
  | _ -> false

let assess_risk ~tool_name ~input =
  let base_risk =
    match classify_with_payload ~tool_name ~input with
    | Some level -> level
    | None -> (
      let baseline = baseline_risk ~tool_name ~input in
      match classify_with_contract_risk ~tool_name ~input with
      | Some level -> max_risk_level baseline level
      | None -> baseline)
  in
  if keeper_mutation_requires_high_floor ~tool_name ~input
  then max_risk_level base_risk High
  else base_risk

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

let maybe_create_petition ~config:_ ~(decision : governance_decision) =
  (* Governance petitions are retired — auto-petition is a no-op.
     High-risk decisions are still logged via audit_decision. *)
  if risk_level_to_int decision.risk >= risk_level_to_int High then
    Log.Governance.info "high-risk tool=%s (petition skipped; governance petitions retired)"
      decision.tool_name

(* ── Pre-Hook Construction ──────────────────────────────────── *)

let make_pre_hook ~config ~governance_level =
  fun ~name ~args ->
    let decision = decide ~governance_level ~tool_name:name ~input:args in
    (* Audit if policy requires it *)
    if should_audit ~governance_level decision.risk then
      audit_decision config decision;
    match decision.action with
    | `Allow -> Tool_dispatch.Pass  (* proceed to handler *)
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
        let response = `Assoc [
          ("status", `String "denied");
          ("trace_id", `String decision.trace_id);
          ("risk_level", `String (risk_level_to_string decision.risk));
          ("governance_level", `String governance_level);
          ("reason", `String reason);
          ("tool_name", `String name);
        ] in
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

(** Build an OAS approval callback that uses governance_pipeline risk
    assessment with genuine HITL fiber suspension.

    When a tool exceeds the governance threshold, the agent fiber is
    suspended via [Keeper_approval_queue.submit_and_await] until an
    operator resolves the approval via the command plane API.

    Tools below the threshold are auto-approved. *)
let to_oas_approval_callback
      ~governance_level ~keeper_name : Oas.Hooks.approval_callback =
  (* B3: Per-decision trifecta. Evaluate on each tool call using current
     shards, not a session-scoped closure capture, so shard grants and
     revocations are reflected immediately in the trifecta state.
     Cost: O(S+T) per call where S=shard count, T=tool count — <1ms. *)
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
        ~risk_level:(risk_level_to_string risk)
    else
      Oas.Hooks.Approve
