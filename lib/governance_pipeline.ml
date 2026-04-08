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

let risk_level_of_contract_risk = function
  | Agent_sdk.Risk_class.Low -> Low
  | Agent_sdk.Risk_class.Medium -> Medium
  | Agent_sdk.Risk_class.High -> High
  | Agent_sdk.Risk_class.Critical -> Critical

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

let tool_names_of_input ~tool_name input =
  let (_ : string) = tool_name in
  collect_string_list_values ~keys:[ "tool_names" ] input
  |> List.sort_uniq String.compare

let classify_with_contract_risk ~tool_name ~input =
  match input with
  | `Assoc _ -> (
      match Team_session_types.delivery_contract_of_yojson
              (Yojson.Safe.Util.member "delivery_contract" input) with
      | Some delivery_contract ->
          let tool_names = tool_names_of_input ~tool_name input in
          Some
            (risk_level_of_contract_risk
               (Contract_risk.of_delivery_contract ~execution_scope:None
                  ~delivery_contract ~tool_names))
      | None -> None)
  | _ -> None

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

let assess_risk ~tool_name ~input =
  match classify_with_payload ~tool_name ~input with
  | Some level -> level
  | None -> (
      let baseline = baseline_risk ~tool_name ~input in
      match classify_with_contract_risk ~tool_name ~input with
      | Some level -> max_risk_level baseline level
      | None -> baseline)

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
  fun ~tool_name ~input ->
    let risk = assess_risk ~tool_name ~input in
    let needs_approval =
      match confirm_threshold governance_level with
      | Some threshold -> risk_level_to_int risk >= risk_level_to_int threshold
      | None -> false
    in
    if needs_approval then
      Keeper_approval_queue.submit_and_await
        ~keeper_name
        ~tool_name
        ~input
        ~risk_level:(risk_level_to_string risk)
    else
      Oas.Hooks.Approve
