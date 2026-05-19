open Keeper_types
open Keeper_runtime_trust_timeline


(* RFC-0047 PR-4: deserialization-boundary normalize for legacy persisted
   wires. Pre-PR-4, [Keeper_turn_terminal.normalize_code] silently remapped
   "completed" → "success" inside [make]. PR-4 retires that table by typing
   producers; old JSON files still carry the legacy wire, so the
   compatibility hop now lives explicitly here at the deserialization
   boundary. New entries are written with the canonical wire by
   [keeper_agent_run.ml]. *)
let normalize_persisted_terminal_reason_code = function
  | "completed" -> "success"
  | code -> code

let terminal_reason_from_decision json =
  match json_member "terminal_reason" json with
  | `Assoc _ as terminal_reason -> Keeper_turn_terminal.of_json terminal_reason
  | _ ->
      Option.map
        (fun code ->
          Keeper_turn_terminal.of_code
            ~source:"decision_log"
            (normalize_persisted_terminal_reason_code code))
        (json_string_opt_member "terminal_reason_code" json)

let terminal_reason_from_receipt receipt =
  let terminal_reason_code = json_string_opt_member "terminal_reason_code" receipt in
  let operator_disposition =
    json_string_opt_member "operator_disposition" receipt
    |> Option.map String.lowercase_ascii
  in
  let operator_disposition_reason =
    json_string_opt_member "operator_disposition_reason" receipt
    |> Option.map String.lowercase_ascii
  in
  let tool_contract_result =
    json_string_opt_member "tool_contract_result" receipt
    |> Option.map String.lowercase_ascii
  in
  let receipt_requires_tool_attention =
    match operator_disposition, operator_disposition_reason, tool_contract_result with
    | Some "pause_human", Some "tool_required_unsatisfied", _
    | _, Some "tool_required_unsatisfied", _
    | _, Some "tool_route_recoverable_failure", _
    | _, _, Some "needs_execution_progress"
    | _, _, Some "missing_required_tool_use"
    | _, _, Some "tool_surface_mismatch"
    | _, _, Some "no_tool_capable_provider"
    | _, _, Some "passive_only"
    | _, _, Some "violated" ->
        true
    | _ -> false
  in
  match terminal_reason_code with
  | Some code when receipt_requires_tool_attention
                   && (String.equal code "completed"
                       || String.equal code "success") ->
      Some
        (Keeper_turn_terminal.of_code ~source:"execution_receipt"
           "required_tool_use_unsatisfied")
  | Some code ->
      Some
        (Keeper_turn_terminal.of_code
           ~source:"execution_receipt"
           (normalize_persisted_terminal_reason_code code))
  | None when receipt_requires_tool_attention ->
      Some
        (Keeper_turn_terminal.of_code ~source:"execution_receipt"
           "required_tool_use_unsatisfied")
  | None -> None

(* JSON-deserialization boundary: maps a runtime_blocker_class wire
   string into a typed [Keeper_turn_disposition.t]. The previous
   variant returned a [terminal_reason_code] wire string that the
   caller then passed back through [Keeper_turn_terminal.of_code]
   for a wire→typed roundtrip; emitting the typed value here removes
   that detour and lets the consumer use [of_disposition] directly.
   The provider-runtime classes preserve their originating blocker
   string in the typed payload instead of collapsing to a single
   "provider_error" literal. *)
let disposition_of_runtime_blocker_class
    : string -> Keeper_turn_disposition.t = function
  | "completion_contract_violation" | "tool_required_unsatisfied" ->
      Keeper_turn_disposition.Required_tool_use_unsatisfied
  | "oas_timeout_budget" ->
      Keeper_turn_disposition.Oas_timeout_budget
  | "turn_timeout" | "turn_timeout_after_queue_wait" | "stale_turn_timeout" ->
      Keeper_turn_disposition.Turn_wall_clock_timeout
  | "ambiguous_post_commit_timeout" | "ambiguous_post_commit_failure" ->
      Keeper_turn_disposition.Post_commit_ambiguous
  | ("cascade_exhausted" | "no_tool_capable_provider"
     | "provider_runtime_error") as cls ->
      Keeper_turn_disposition.Provider_error
        (Keeper_turn_terminal_code.Provider_runtime_error cls)
  | _ ->
      Keeper_turn_disposition.Unknown { raw_error = "" }

let terminal_reason_from_runtime_blocker_fields runtime_blocker_fields =
  match assoc_string_opt "runtime_blocker_class" runtime_blocker_fields with
  | None -> None
  | Some blocker_class ->
      let disposition = disposition_of_runtime_blocker_class blocker_class in
      let summary = assoc_string_opt "runtime_blocker_summary" runtime_blocker_fields in
      Some
        (Keeper_turn_terminal.of_disposition
           ~source:"runtime_blocker"
           ?summary
           disposition)

let receipt_ended_at_unix receipt =
  match json_string_opt_member "ended_at" receipt with
  | Some ended_at ->
      let ts = Masc_domain.parse_iso8601 ~default_time:0.0 ended_at in
      if ts > 0.0 then Some ts else None
  | None -> None

(* Receipt timestamps are serialized as whole-second ISO strings, while runtime
   last-turn observations keep fractional seconds.  A same-second receipt must
   still be allowed to explain the blocker; otherwise the runtime blocker
   silently overrides its operator disposition. *)
let runtime_blocker_receipt_timestamp_epsilon_sec = 1.0

let runtime_blocker_supersedes_receipt ~meta ~runtime_blocker_fields
    latest_receipt =
  match assoc_string_opt "runtime_blocker_class" runtime_blocker_fields with
  | None -> false
  | Some _ -> (
      match latest_receipt with
      | None -> true
      | Some receipt -> (
          match receipt_ended_at_unix receipt with
          | Some receipt_ts ->
              meta.runtime.usage.last_turn_ts
              > receipt_ts +. runtime_blocker_receipt_timestamp_epsilon_sec
          | None -> meta.runtime.usage.last_turn_ts > 0.0))

let current_receipt_for_runtime_state ~meta ~runtime_blocker_fields
    latest_receipt =
  if runtime_blocker_supersedes_receipt ~meta ~runtime_blocker_fields
       latest_receipt
  then None
  else latest_receipt

let runtime_blocker_timeline_ts ~meta ~runtime_blocker_fields latest_receipt =
  if
    runtime_blocker_supersedes_receipt ~meta ~runtime_blocker_fields
      latest_receipt
    && meta.runtime.usage.last_turn_ts > 0.0
  then meta.runtime.usage.last_turn_ts
  else Time_compat.now ()

let latest_terminal_reason_opt ~meta ~runtime_blocker_fields ~latest_decision
    ~latest_receipt =
  match Option.bind latest_decision terminal_reason_from_decision with
  | Some _ as value -> value
  | None ->
      if runtime_blocker_supersedes_receipt ~meta ~runtime_blocker_fields
           latest_receipt
      then terminal_reason_from_runtime_blocker_fields runtime_blocker_fields
      else Option.bind latest_receipt terminal_reason_from_receipt

let terminal_reason_timeline_event ~latest_decision ~latest_receipt =
  let source_json, ts_unix_opt, reason_opt =
    match latest_decision with
    | Some decision -> (
        match terminal_reason_from_decision decision with
        | Some reason ->
            ( Some decision,
              (match json_float_opt_member "ts_unix" decision with
               | Some _ as value -> value
               | None -> json_float_opt_member "wall_clock" decision),
              Some reason )
        | None -> (None, None, None))
    | None -> (None, None, None)
  in
  let source_json, ts_unix_opt, reason_opt =
    match reason_opt, latest_receipt with
    | Some _, _ -> (source_json, ts_unix_opt, reason_opt)
    | None, Some receipt -> (
        match terminal_reason_from_receipt receipt with
        | Some reason ->
            let ts_unix_opt =
              match json_string_opt_member "ended_at" receipt with
              | Some ended_at ->
                  let ts = Masc_domain.parse_iso8601 ~default_time:0.0 ended_at in
                  if ts > 0.0 then Some ts else None
              | None -> None
            in
            (Some receipt, ts_unix_opt, Some reason)
        | None -> (None, None, None))
    | None, None -> (None, None, None)
  in
  match source_json, ts_unix_opt, reason_opt with
  | Some source_json, Some ts_unix, Some reason ->
      Some
        (timeline_event_json
           ?trace_id:(json_string_opt_member "trace_id" source_json)
           ?keeper_turn_id:(keeper_turn_id_of_json source_json)
           ?task_id:
             (match json_string_opt_member "task_id" source_json with
              | Some _ as value -> value
              | None -> json_string_opt_member "current_task_id" source_json)
           ~goal_ids:(goal_ids_of_json source_json)
           ?next_human_action:reason.next_action
           ~ts_unix ~kind:"terminal_reason"
           ~title:"Terminal Reason"
           ~summary:reason.summary
           ~severity:(Keeper_turn_terminal.severity_to_string reason.severity)
           ())
  | _ -> None

let disposition_of_snapshot ~pending_approval_count ~runtime_blocker_fields =
  let continue_gate =
    assoc_bool_default "runtime_blocker_continue_gate" ~default:false
      runtime_blocker_fields
  in
  let blocker_class = assoc_string_opt "runtime_blocker_class" runtime_blocker_fields in
  let blocker_summary =
    assoc_string_opt "runtime_blocker_summary" runtime_blocker_fields
  in
  if pending_approval_count > 0 then ("Blocked", "waiting_approval")
  else if continue_gate then ("Blocked", "waiting_human_decision")
  else
    match blocker_class, blocker_summary with
    | Some "cascade_exhausted", _ -> ("Alert", "cascade_exhausted")
    | Some "completion_contract_violation", _ -> ("Alert", "fsm_invariant")
    | _, Some summary
      when String_util.contains_substring_ci summary "sandbox" ->
        ("Alert", "sandbox_violation")
    | Some _, _ -> ("Alert", "critical_block")
    | None, _ -> ("Pass", "healthy")

let operator_disposition_of_display ~disposition ~disposition_reason =
  match disposition with
  | "Pass" -> ("pass", disposition_reason)
  | "Blocked" -> ("pause_human", disposition_reason)
  | "Pause" -> ("pause_human", disposition_reason)
  | "Alert" -> ("alert_exhausted", disposition_reason)
  | _ -> ("pause_human", disposition_reason)

let display_disposition_of_operator ~operator_disposition
    ~operator_disposition_reason =
  let reason default =
    match String.trim operator_disposition_reason with
    | "" -> default
    | value -> value
  in
  match String.lowercase_ascii operator_disposition with
  | "pass" -> ("Pass", "healthy")
  | "skipped" -> ("Pass", "phase_skipped")
  | "pass_next_model" -> ("Pass", "cascade_fallback")
  | "blocked" | "blocked_runtime" -> ("Blocked", reason "runtime_blocked")
  | "pause_human" -> ("Blocked", reason "needs_human_attention")
  | "fail_open_next_cascade" -> ("Blocked", reason "degraded_retry")
  | "user_cancelled" -> ("Blocked", reason "cancelled")
  | "alert_exhausted" -> ("Alert", reason "cascade_exhausted")
  | "unknown" -> ("Alert", reason "unmapped_cascade_state")
  | _ -> ("Alert", reason "unmapped_operator_disposition")

let display_disposition_requires_attention = function
  | "Blocked" | "Pause" | "Alert" -> true
  | _ -> false

let receipt_operator_disposition receipt =
  match
    ( json_string_opt_member "operator_disposition" receipt,
      json_string_opt_member "operator_disposition_reason" receipt )
  with
  | Some disposition, Some reason -> Some (disposition, reason)
  | Some disposition, None -> Some (disposition, "")
  | None, _ -> None

let effective_disposition_fields ~fallback_disposition ~fallback_reason
    latest_receipt =
  match Option.bind latest_receipt receipt_operator_disposition with
  | Some (operator_disposition, operator_disposition_reason) ->
      let disposition, disposition_reason =
        display_disposition_of_operator ~operator_disposition
          ~operator_disposition_reason
      in
      ( disposition,
        disposition_reason,
        operator_disposition,
        operator_disposition_reason )
  | None ->
      let operator_disposition, operator_disposition_reason =
        operator_disposition_of_display ~disposition:fallback_disposition
          ~disposition_reason:fallback_reason
      in
      ( fallback_disposition,
        fallback_reason,
        operator_disposition,
        operator_disposition_reason )

let attention_reason_or_disposition ~needs_attention ~disposition_reason
    attention_fields =
  match assoc_string_opt "attention_reason" attention_fields with
  | Some _ as value -> value
  | None when needs_attention -> Some disposition_reason
  | None -> None

let next_human_action_or_terminal ~needs_attention ~latest_next_action
    attention_fields =
  match assoc_string_opt "next_human_action" attention_fields with
  | Some _ as value -> value
  | None when needs_attention -> latest_next_action
  | None -> None

let disposition_fields_json ~(config : Coord.config) ~(meta : keeper_meta) :
    Yojson.Safe.t =
  let pending_approval_count =
    Keeper_approval_queue.pending_count_for_keeper ~keeper_name:meta.name
  in
  let runtime_blocker_fields =
    Keeper_status_bridge.runtime_blocker_fields_json config meta
  in
  let disposition, disposition_reason =
    disposition_of_snapshot ~pending_approval_count ~runtime_blocker_fields
  in
  let latest_receipt = Keeper_execution_receipt.latest_json config meta.name in
  let disposition, disposition_reason, _, _ =
    effective_disposition_fields ~fallback_disposition:disposition
      ~fallback_reason:disposition_reason latest_receipt
  in
  `Assoc
    [
      ("disposition", `String disposition);
      ("disposition_reason", `String disposition_reason);
    ]

let decision_log_persistence_surface = "keeper_runtime_trust_decision_log"

let report_decision_log_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Prometheus.inc_counter Prometheus.metric_persistence_read_drops
        ~labels:[("surface", decision_log_persistence_surface); ("reason", reason)]
        ())
    ~surface:decision_log_persistence_surface
    ~reason
    ~path
    ~detail

let latest_decision_json ~(config : Coord.config) ~(keeper_name : string) :
    Yojson.Safe.t option =
  let path = Keeper_types.keeper_decision_log_path config keeper_name in
  if not (Fs_compat.file_exists path) then None
  else
    Keeper_memory.read_file_tail_lines path ~max_bytes:40000 ~max_lines:20
    |> List.rev
    |> List.find_map (fun line ->
           match Yojson.Safe.from_string line with
           | exception Yojson.Json_error detail ->
               report_decision_log_read_drop
                 ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
                 ~path
                 ~detail;
               None
           | (`Assoc _ as json) -> Some json
           | _ ->
               report_decision_log_read_drop
                 ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                 ~path
                 ~detail:"decision log row is not a JSON object";
               None)


let latest_turn_id ~(registry_entry : Keeper_registry.registry_entry option)
    ~(latest_decision : Yojson.Safe.t option)
    ~(latest_tool_call : Yojson.Safe.t option)
    ~(latest_receipt : Yojson.Safe.t option) =
  match Option.bind latest_decision (json_int_opt_member "turn_id") with
  | Some _ as turn_id -> turn_id
  | None ->
      (match Option.bind latest_tool_call (json_int_opt_member "keeper_turn_id") with
       | Some _ as turn_id -> turn_id
       | None ->
           (match Option.bind latest_receipt (json_int_opt_member "turn_count") with
            | Some _ as turn_id -> turn_id
            | None -> (
                match registry_entry with
                | Some { current_turn_observation = Some turn; _ } -> Some turn.turn_id
                | Some { last_completed_turn = Some turn; _ } -> Some turn.ct_turn_id
                | _ -> None)))

let latest_receipt_json ~(config : Coord.config) ~(keeper_name : string) =
  Keeper_execution_receipt.latest_json config keeper_name

let selected_model_of_latest_decision latest_decision =
  Option.bind latest_decision (fun decision ->
      match
        decision |> json_member "telemetry"
        |> json_string_opt_member "selected_model"
      with
      | Some _ as value -> value
      | None -> json_string_opt_member "selected_model" decision)

let pending_first_json pending_approvals =
  match pending_approvals with
  | `List (first :: _) ->
      let tool_name = json_string_opt_member "tool_name" first in
      let approval_id = json_string_opt_member "id" first in
      let task_id = json_string_opt_member "task_id" first in
      let blocker_class =
        match tool_name with
        | Some t when is_worktree_tool t -> Some "blocked_before_worktree"
        | _ -> None
      in
      `Assoc
        [
          ("id", Json_util.string_opt_to_json approval_id);
          ("tool_name", Json_util.string_opt_to_json tool_name);
          ("task_id", Json_util.string_opt_to_json task_id);
          ("blocker_class", Json_util.string_opt_to_json blocker_class);
        ]
  | _ -> `Null

let approval_state_json ~pending_approval_count ~pending_approvals ~latest_tool_call
    ~latest_approval_audit ~latest_receipt =
  let latest_rule_match =
    Option.bind latest_approval_audit (fun json ->
        match json_member "rule_match" json with
        | `Assoc _ as rule_match -> Some rule_match
        | _ -> None)
  in
  let latest_event_kind =
    Option.bind latest_approval_audit (json_string_opt_member "event")
  in
  let resolution_mode =
    Option.bind latest_tool_call (json_string_opt_member "approval_mode")
  in
  let approval_profile =
    Option.bind latest_receipt (fun receipt ->
        receipt |> json_member "approval"
        |> json_string_opt_member "profile")
  in
  let state =
    if pending_approval_count > 0 then "pending"
    else
      match latest_event_kind with
      | Some "auto_approved_always" -> "always_flag"
      | Some "auto_approved_rule_match" -> "always_rule"
      | Some "resolved" -> "resolved"
      | Some "expired" | Some "approval_timeout" -> "expired"
      | Some "cancelled" -> "cancelled"
      | Some _ -> "observed"
      | None -> "idle"
  in
  `Assoc
    [
      ("state", `String state);
      ("pending_count", `Int pending_approval_count);
      ("profile", Json_util.string_opt_to_json approval_profile);
      ("resolution_mode", Json_util.string_opt_to_json resolution_mode);
      ("latest_event_kind", Json_util.string_opt_to_json latest_event_kind);
      ( "latest_event_at",
        match Option.bind latest_approval_audit (json_float_opt_member "ts") with
        | Some ts -> `String (iso_of_unix_seconds ts)
        | None -> `Null );
      ( "matched_by",
        match latest_rule_match with
        | Some json -> json |> json_string_opt_member "matched_by" |> Json_util.string_opt_to_json
        | None -> `Null );
      ( "rule_id",
        match latest_rule_match with
        | Some json -> json |> json_string_opt_member "rule_id" |> Json_util.string_opt_to_json
        | None -> `Null );
      ( "auto_approved",
        match latest_approval_audit with
        | Some json ->
            json_bool_opt_member "auto_approved" json
            |> Json_util.bool_opt_to_json
        | None -> `Null );
      ("pending_first", pending_first_json pending_approvals);
    ]

let execution_summary_json ~meta ~latest_receipt =
  let sandbox_kind =
    match latest_receipt with
    | Some receipt ->
        receipt |> json_member "sandbox"
        |> json_string_opt_member "kind"
    | None -> Some (Keeper_types.sandbox_profile_to_string meta.sandbox_profile)
  in
  let network_mode =
    match latest_receipt with
    | Some receipt ->
        receipt |> json_member "sandbox"
        |> json_string_opt_member "network_mode"
    | None -> Some (Keeper_types.network_mode_to_string meta.network_mode)
  in
  let sandbox_root =
    match latest_receipt with
    | Some receipt ->
        receipt |> json_member "sandbox"
        |> json_string_opt_member "sandbox_root"
    | None -> None
  in
  let tool_contract_result =
    Option.bind latest_receipt (json_string_opt_member "tool_contract_result")
  in
  let requested_tools =
    match latest_receipt with
    | Some receipt -> json_string_list_member "requested_tools" receipt
    | None -> []
  in
  let tools_used =
    match latest_receipt with
    | Some receipt -> json_string_list_member "tools_used" receipt
    | None -> []
  in
  let unexpected_tools =
    match latest_receipt with
    | Some receipt -> json_string_list_member "unexpected_tools" receipt
    | None -> []
  in
  let required_tools, required_tool_candidates, missing_required_tools =
    match latest_receipt with
    | Some receipt ->
        let surface = json_member "tool_surface" receipt in
        ( json_string_list_member "required_tools" surface,
          json_string_list_member "required_tool_candidates" surface,
          json_string_list_member "missing_required_tools" surface )
    | None -> [], [], []
  in
  let cascade_json =
    match latest_receipt with
    | Some receipt -> json_member "cascade" receipt
    | None -> `Null
  in
  let cascade_attempt_count =
    match cascade_json with
    | `Null -> None
    | json -> json_int_opt_member "attempt_count" json
  in
  let cascade_fallback_applied =
    match cascade_json with
    | `Null -> None
    | json -> json_bool_opt_member "fallback_applied" json
  in
  let cascade_outcome =
    match cascade_json with
    | `Null -> None
    | json -> json_string_opt_member "outcome" json
  in
  let mutation_guard_summary =
    match tool_contract_result with
    | Some "violated" -> "mutation_contract_violated"
    | Some ("satisfied" | "satisfied_execution" | "satisfied_completion") ->
        "mutation_contract_satisfied"
    | Some other -> other
    | None -> "mutation_contract_not_observed"
  in
  `Assoc
    [
      ("tool_contract_result", Json_util.string_opt_to_json tool_contract_result);
      ( "runtime_proof_status",
        Json_util.string_opt_to_json tool_contract_result );
      ("required_tools", string_list_json required_tools);
      ("required_tool_candidates", string_list_json required_tool_candidates);
      ("missing_required_tools", string_list_json missing_required_tools);
      ("requested_tools", string_list_json requested_tools);
      ("tools_used", string_list_json tools_used);
      ("unexpected_tools", string_list_json unexpected_tools);
      ("requested_tool_count", `Int (List.length requested_tools));
      ("tools_used_count", `Int (List.length tools_used));
      ("unexpected_tool_count", `Int (List.length unexpected_tools));
      ( "provider_attempt_count",
        match cascade_attempt_count with
        | Some value -> `Int value
        | None -> `Null );
      ( "provider_fallback_applied",
        match cascade_fallback_applied with
        | Some value -> `Bool value
        | None -> `Null );
      ( "provider_selected_model",
        `Null );
      ( "cascade_outcome",
        Json_util.string_opt_to_json cascade_outcome );
      ( "sandbox_summary",
        match (sandbox_kind, network_mode) with
        | Some kind, Some mode -> `String (Printf.sprintf "%s / %s" kind mode)
        | Some kind, None -> `String kind
        | None, Some mode -> `String mode
        | None, None -> `Null );
      ("sandbox_root", Json_util.string_opt_to_json sandbox_root);
      ("mutation_guard_summary", `String mutation_guard_summary);
      ( "latest_receipt_at",
        match Option.bind latest_receipt (json_string_opt_member "ended_at") with
        | Some value -> `String value
        | None -> `Null );
    ]

let latest_causal_event_summary ~meta ~latest_decision ~latest_receipt
    ~latest_tool_call ~latest_approval_audit ~runtime_blocker_fields
    ~next_human_action =
  let observed_at_unix =
    runtime_blocker_timeline_ts ~meta ~runtime_blocker_fields latest_receipt
  in
  let blocker_observation_only =
    not
      (runtime_blocker_supersedes_receipt ~meta ~runtime_blocker_fields
         latest_receipt)
  in
  let task_id = Keeper_runtime_contract.current_task_id_opt meta in
  let goal_ids = meta.active_goal_ids in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  [
    terminal_reason_timeline_event ~latest_decision ~latest_receipt;
    Option.bind latest_decision decision_timeline_event;
    Option.bind latest_receipt receipt_timeline_event;
    Option.bind latest_tool_call tool_call_timeline_event;
    Option.bind latest_approval_audit approval_event_timeline_event;
    blocker_timeline_event ~ts_unix:observed_at_unix ~observed_at_unix
      ~runtime_blocker_fields ?task_id ~goal_ids
      ~trace_id ~next_human_action
      ~observation_only:blocker_observation_only ();
  ]
  |> List.filter_map Fun.id
  |> sort_timeline_events
  |> fun events -> latest_causal_from_timeline (`List events)

let summary_json ~(config : Coord.config) ~(meta : keeper_meta) =
  let latest_decision = latest_decision_json ~config ~keeper_name:meta.name in
  let latest_tool_call = latest_tool_call_json ~keeper_name:meta.name in
  let latest_receipt = latest_receipt_json ~config ~keeper_name:meta.name in
  let latest_approval_audit =
    match
      Keeper_approval_queue.read_recent_audit ~base_path:config.base_path
        ~keeper_name:meta.name ~n:1 ()
    with
    | json :: _ -> Some json
    | [] -> None
  in
  let pending_approval_count =
    Keeper_approval_queue.pending_count_for_keeper ~keeper_name:meta.name
  in
  let runtime_blocker_fields =
    Keeper_status_bridge.runtime_blocker_fields_json config meta
  in
  let latest_receipt_for_runtime_state =
    current_receipt_for_runtime_state ~meta ~runtime_blocker_fields
      latest_receipt
  in
  let latest_terminal_reason =
    latest_terminal_reason_opt ~meta ~runtime_blocker_fields ~latest_decision
      ~latest_receipt
  in
  let latest_terminal_reason_json =
    latest_terminal_reason
    |> Option.map Keeper_turn_terminal.to_json
    |> Option.value ~default:`Null
  in
  let latest_next_action =
    Option.bind latest_terminal_reason (fun reason -> reason.next_action)
  in
  let attention_fields =
    Keeper_status_bridge.attention_fields_json config meta
  in
  let fallback_disposition, fallback_disposition_reason =
    disposition_of_snapshot ~pending_approval_count ~runtime_blocker_fields
  in
  let disposition, disposition_reason, operator_disposition,
      operator_disposition_reason =
    effective_disposition_fields ~fallback_disposition
      ~fallback_reason:fallback_disposition_reason
      latest_receipt_for_runtime_state
  in
  let needs_attention =
    assoc_bool_default "needs_attention" ~default:false attention_fields
    || display_disposition_requires_attention disposition
  in
  let attention_reason =
    attention_reason_or_disposition ~needs_attention ~disposition_reason
      attention_fields
  in
  let next_human_action =
    next_human_action_or_terminal ~needs_attention ~latest_next_action
      attention_fields
  in
  let execution_summary =
    execution_summary_json ~meta ~latest_receipt
  in
  let latest_causal_event =
    latest_causal_event_summary ~meta ~latest_decision ~latest_receipt
      ~latest_tool_call ~latest_approval_audit
      ~runtime_blocker_fields ~next_human_action
  in
  `Assoc
    [
      ("disposition", `String disposition);
      ("disposition_reason", `String disposition_reason);
      ("operator_disposition", `String operator_disposition);
      ("operator_disposition_reason", `String operator_disposition_reason);
      ("needs_attention", `Bool needs_attention);
      ("attention_reason", Json_util.string_opt_to_json attention_reason);
      ("next_human_action", Json_util.string_opt_to_json next_human_action);
      ("execution", execution_summary);
      ("latest_terminal_reason", latest_terminal_reason_json);
      ("latest_next_action", Json_util.string_opt_to_json latest_next_action);
      ("latest_causal_event", latest_causal_event);
    ]

let causal_timeline_json ~base_path ~meta ~latest_decision ~latest_receipt
    ~latest_tool_call ~latest_approval_audit ~runtime_blocker_fields
    ~next_human_action =
  let tool_events =
    Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:6 ()
    |> List.filter_map tool_call_timeline_event
  in
  let approval_events =
    Keeper_approval_queue.read_recent_audit ~base_path ~keeper_name:meta.name
      ~n:8 ()
    |> List.filter_map approval_event_timeline_event
  in
  let transition_events =
    match Keeper_transition_audit.recent_transitions_json
            ~keeper_name:meta.name ~limit:6 with
    | `List items -> items |> List.filter_map transition_timeline_event
    | _ -> []
  in
  let decision_events =
    (match latest_decision with
     | Some json -> [ decision_timeline_event json ]
     | None -> [])
    |> List.filter_map Fun.id
  in
  let receipt_events =
    (match latest_receipt with
     | Some receipt -> [ receipt_timeline_event receipt ]
     | None -> [])
    |> List.filter_map Fun.id
  in
  let terminal_reason_events =
    [ terminal_reason_timeline_event ~latest_decision ~latest_receipt ]
    |> List.filter_map Fun.id
  in
  let blocker_events =
    let task_id = Keeper_runtime_contract.current_task_id_opt meta in
    let goal_ids = meta.active_goal_ids in
    let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let observed_at_unix =
      runtime_blocker_timeline_ts ~meta ~runtime_blocker_fields latest_receipt
    in
    let blocker_observation_only =
      not
        (runtime_blocker_supersedes_receipt ~meta ~runtime_blocker_fields
           latest_receipt)
    in
    [
      blocker_timeline_event ~ts_unix:observed_at_unix ~observed_at_unix
        ~runtime_blocker_fields ?task_id ~goal_ids
        ~trace_id ~next_human_action
        ~observation_only:blocker_observation_only ()
    ]
    |> List.filter_map Fun.id
  in
  let latest_tool_call_event =
    match latest_tool_call with
    | Some json -> tool_call_timeline_event json
    | None -> None
  in
  let latest_approval_event =
    match latest_approval_audit with
    | Some json -> approval_event_timeline_event json
    | None -> None
  in
  let dedupe_key json =
    let kind = json_string_opt_member "kind" json |> Option.value ~default:"" in
    let ts = json_string_opt_member "ts" json |> Option.value ~default:"" in
    let title = json_string_opt_member "title" json |> Option.value ~default:"" in
    kind ^ "|" ^ ts ^ "|" ^ title
  in
  let dedupe acc item =
    let key = dedupe_key item in
    if List.exists (fun existing -> String.equal key (dedupe_key existing)) acc
    then acc
    else item :: acc
  in
  let live_pending_events =
    match pending_approval_json ~keeper_name:meta.name with
    | `List entries -> List.filter_map live_pending_approval_timeline_event entries
    | _ -> []
  in
  tool_events @ approval_events @ transition_events @ terminal_reason_events
  @ decision_events @ receipt_events @ blocker_events @ live_pending_events
  @ (List.filter_map Fun.id [ latest_tool_call_event; latest_approval_event ])
  |> List.fold_left dedupe []
  |> sort_timeline_events
  |> take 12
  |> fun items -> `List items

let snapshot_json ~(config : Coord.config) ~(meta : keeper_meta) =
  let registry_entry =
    Keeper_registry.get ~base_path:config.base_path meta.name
  in
  let latest_decision = latest_decision_json ~config ~keeper_name:meta.name in
  let latest_tool_call = latest_tool_call_json ~keeper_name:meta.name in
  let latest_receipt = latest_receipt_json ~config ~keeper_name:meta.name in
  let latest_approval_audit =
    match
      Keeper_approval_queue.read_recent_audit ~base_path:config.base_path
        ~keeper_name:meta.name ~n:1 ()
    with
    | json :: _ -> Some json
    | [] -> None
  in
  let pending_approvals = pending_approval_json ~keeper_name:meta.name in
  let pending_approval_count =
    match pending_approvals with
    | `List entries -> List.length entries
    | _ -> 0
  in
  let runtime_blocker_fields =
    Keeper_status_bridge.runtime_blocker_fields_json config meta
  in
  let latest_receipt_for_runtime_state =
    current_receipt_for_runtime_state ~meta ~runtime_blocker_fields
      latest_receipt
  in
  let latest_terminal_reason =
    latest_terminal_reason_opt ~meta ~runtime_blocker_fields ~latest_decision
      ~latest_receipt
  in
  let latest_terminal_reason_json =
    latest_terminal_reason
    |> Option.map Keeper_turn_terminal.to_json
    |> Option.value ~default:`Null
  in
  let latest_next_action =
    Option.bind latest_terminal_reason (fun reason -> reason.next_action)
  in
  let selected_model = selected_model_of_latest_decision latest_decision in
  let attention_fields =
    Keeper_status_bridge.attention_fields_json config meta
  in
  let runtime_phase =
    match registry_entry with
    | Some entry -> `String (Keeper_state_machine.phase_to_string entry.phase)
    | None -> `Null
  in
  let runtime_contract =
    Keeper_runtime_contract.runtime_contract_json ~config meta
  in
  let fallback_disposition, fallback_disposition_reason =
    disposition_of_snapshot ~pending_approval_count ~runtime_blocker_fields
  in
  let disposition, disposition_reason, operator_disposition,
      operator_disposition_reason =
    effective_disposition_fields ~fallback_disposition
      ~fallback_reason:fallback_disposition_reason
      latest_receipt_for_runtime_state
  in
  let needs_attention =
    assoc_bool_default "needs_attention" ~default:false attention_fields
    || display_disposition_requires_attention disposition
  in
  let attention_reason =
    attention_reason_or_disposition ~needs_attention ~disposition_reason
      attention_fields
  in
  let next_human_action =
    next_human_action_or_terminal ~needs_attention ~latest_next_action
      attention_fields
  in
  let approval_state =
    approval_state_json ~pending_approval_count ~pending_approvals
      ~latest_tool_call ~latest_approval_audit ~latest_receipt
  in
  let execution_summary =
    execution_summary_json ~meta ~latest_receipt
  in
  let causal_timeline =
    causal_timeline_json ~base_path:config.base_path ~meta ~latest_decision
      ~latest_receipt
      ~latest_tool_call ~latest_approval_audit
      ~runtime_blocker_fields ~next_human_action
  in
  let latest_causal_event =
    latest_causal_from_timeline causal_timeline
  in
  `Assoc
    [
      ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
      ("generation", `Int meta.runtime.generation);
      ( "turn_id",
        match
          latest_turn_id ~registry_entry ~latest_decision ~latest_tool_call
            ~latest_receipt
        with
        | Some turn_id -> `Int turn_id
        | None -> `Null );
      ("phase", runtime_phase);
      ("raw_phase", runtime_phase);
      ("current_task_id", Json_util.string_opt_to_json (Keeper_runtime_contract.current_task_id_opt meta));
      ("goal_id", Json_util.string_opt_to_json (Keeper_runtime_contract.primary_goal_id_opt meta));
      ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids));
      ("active_model", Json_util.string_opt_to_json selected_model);
      ("selected_model", Json_util.string_opt_to_json selected_model);
      ("runtime_contract", runtime_contract);
      ("runtime_blockers", `Assoc runtime_blocker_fields);
      ("disposition", `String disposition);
      ("disposition_reason", `String disposition_reason);
      ("operator_disposition", `String operator_disposition);
      ("operator_disposition_reason", `String operator_disposition_reason);
      ("needs_attention", `Bool needs_attention);
      ("attention_reason", Json_util.string_opt_to_json attention_reason);
      ("next_human_action", Json_util.string_opt_to_json next_human_action);
      ("approval", approval_state);
      ("execution", execution_summary);
      ("latest_terminal_reason", latest_terminal_reason_json);
      ("latest_next_action", Json_util.string_opt_to_json latest_next_action);
      ("pending_approval_count", `Int pending_approval_count);
      ("pending_approvals", pending_approvals);
      ("latest_decision", Option.value ~default:`Null latest_decision);
      ("latest_tool_call", Option.value ~default:`Null latest_tool_call);
      ("latest_receipt", Option.value ~default:`Null latest_receipt);
      ("latest_causal_event", latest_causal_event);
      ("causal_timeline", causal_timeline);
      ( "last_event_bus_correlation",
        match registry_entry with
        | Some entry ->
            Json_util.string_opt_to_json entry.last_event_bus_correlation
        | None -> `Null );
    ]
