type tool_surface =
  { turn_lane : string
  ; tool_surface_class : string
  ; tool_requirement : string
  ; visible_tool_count : int
  ; tool_gate_enabled : bool
  ; tool_surface_fallback_used : bool
  }

type cascade_rotation_attempt =
  { from_cascade : string
  ; to_cascade : string
  ; reason : string
  ; outcome : string
  ; error_kind : string option
  ; error_message : string option
  ; recorded_at : string
  }

type t =
  { keeper_name : string
  ; agent_name : string
  ; trace_id : string
  ; generation : int
  ; turn_count : int option
  ; current_task_id : string option
  ; goal_ids : string list
  ; outcome : string
  ; terminal_reason_code : string
  ; response_text_present : bool
  ; model_used : string option
  ; requested_tools : string list
  ; reported_tools : string list
  ; observed_tools : string list
  ; canonical_tools : string list
  ; unexpected_tools : string list
  ; tools_used : string list
  ; tool_contract_result : string
  ; tool_surface : tool_surface
  ; sandbox_kind : string
  ; sandbox_root : string option
  ; network_mode : string
  ; approval_profile : string option
  ; approval_profile_derived : bool
  ; cascade_name : string
  ; cascade_selected_model : string option
  ; cascade_attempt_count : int
  ; cascade_fallback_applied : bool
  ; cascade_outcome : string
  ; degraded_retry_applied : bool
  ; degraded_retry_cascade : string option
  ; fallback_reason : string option
  ; cascade_rotation_attempts : cascade_rotation_attempt list
  ; stop_reason : string option
  ; error_kind : string option
  ; error_message : string option
  ; started_at : string
  ; ended_at : string
  }

let stop_reason_to_string = function
  | Oas_worker.Completed -> "completed"
  | Oas_worker.TurnBudgetExhausted { turns_used; limit } ->
    Printf.sprintf "turn_budget_exhausted:%d/%d" turns_used limit
  | Oas_worker.MutationBoundaryReached { turns_used; tool_name } ->
    (match tool_name with
     | Some tool ->
       Printf.sprintf "mutation_boundary:%s:%d" tool turns_used
     | None ->
       Printf.sprintf "mutation_boundary:%d" turns_used)

let sandbox_kind_of_meta (meta : Keeper_types.keeper_meta) =
  match meta.sandbox_profile with
  | Keeper_types.Docker -> "docker"
  | Keeper_types.Local -> "local"

let list_json values =
  `List (List.map (fun value -> `String value) values)

let string_opt_json = function
  | Some value -> `String value
  | None -> `Null

let cascade_rotation_attempt_to_json attempt =
  `Assoc
    [
      ("from_cascade", `String attempt.from_cascade);
      ("to_cascade", `String attempt.to_cascade);
      ("reason", `String attempt.reason);
      ("outcome", `String attempt.outcome);
      ("error_kind", string_opt_json attempt.error_kind);
      ("error_message", string_opt_json attempt.error_message);
      ("recorded_at", `String attempt.recorded_at);
    ]

let string_contains_ci haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if needle_len = 0 then true
    else if i + needle_len > haystack_len then false
    else if String.sub haystack i needle_len = needle then true
    else loop (i + 1)
  in
  loop 0

let operator_disposition (receipt : t) =
  let cascade_outcome = String.lowercase_ascii receipt.cascade_outcome in
  let terminal_reason = String.lowercase_ascii receipt.terminal_reason_code in
  let error_kind =
    Option.map String.lowercase_ascii receipt.error_kind
  in
  if
    String.equal terminal_reason "cascade_exhausted"
    || String.equal cascade_outcome "cascade_exhausted"
    || String.equal cascade_outcome "exhausted"
  then ("alert_exhausted", "cascade_exhausted")
  else if
    String.equal receipt.tool_surface.tool_requirement "required"
    && (not (String.equal receipt.tool_contract_result "satisfied")
        || receipt.tools_used = [])
  then ("pause_human", "tool_required_unsatisfied")
  else if
    match error_kind with
    | Some kind ->
        string_contains_ci kind "config"
        || string_contains_ci kind "auth"
        || string_contains_ci terminal_reason "config"
        || string_contains_ci terminal_reason "auth"
    | None ->
        string_contains_ci terminal_reason "config"
        || string_contains_ci terminal_reason "auth"
  then ("pause_human", "preflight_config_error")
  else if receipt.degraded_retry_applied || Option.is_some receipt.degraded_retry_cascade
  then ("fail_open_next_cascade", "degraded_retry")
  else if
    receipt.cascade_fallback_applied
    || String.equal cascade_outcome "passed_to_next_model"
  then ("pass_next_model", "cascade_fallback")
  (* "healthy" requires an explicit success signal: turn completed without
     error AND cascade reached the configured terminal. Any other fallthrough
     is an unmapped state — surface it as "unknown" so a new cascade_outcome
     or terminal_reason_code does not silently display as "healthy" on the
     dashboard. See #9900 and CLAUDE.md anti-pattern #2. *)
  else if
    String.equal receipt.outcome "ok"
    && String.equal cascade_outcome "completed"
  then ("pass", "healthy")
  else ("unknown", "unmapped_cascade_state")

let to_json (receipt : t) =
  let operator_disposition, operator_disposition_reason =
    operator_disposition receipt
  in
  let error_json =
    match receipt.error_kind, receipt.error_message with
    | None, None -> `Null
    | error_kind, error_message ->
      `Assoc
        [
          ( "kind",
            match error_kind with
            | Some value -> `String value
            | None -> `Null );
          ( "message",
            match error_message with
            | Some value -> `String value
            | None -> `Null );
        ]
  in
  `Assoc
    [
      ("schema", `String "keeper.execution_receipt.v1");
      ("recorded_at", `String receipt.ended_at);
      ("keeper_name", `String receipt.keeper_name);
      ("agent_name", `String receipt.agent_name);
      ("trace_id", `String receipt.trace_id);
      ("generation", `Int receipt.generation);
      ( "turn_count",
        match receipt.turn_count with
        | Some value -> `Int value
        | None -> `Null );
      ( "current_task_id",
        match receipt.current_task_id with
        | Some value -> `String value
        | None -> `Null );
      ("goal_ids", list_json receipt.goal_ids);
      ("outcome", `String receipt.outcome);
      ("terminal_reason_code", `String receipt.terminal_reason_code);
      ("operator_disposition", `String operator_disposition);
      ("operator_disposition_reason", `String operator_disposition_reason);
      ("response_text_present", `Bool receipt.response_text_present);
      ( "model_used",
        match receipt.model_used with
        | Some value -> `String value
        | None -> `Null );
      ("requested_tools", list_json receipt.requested_tools);
      ("reported_tools", list_json receipt.reported_tools);
      ("observed_tools", list_json receipt.observed_tools);
      ("canonical_tools", list_json receipt.canonical_tools);
      ("unexpected_tools", list_json receipt.unexpected_tools);
      ("tools_used", list_json receipt.tools_used);
      ("tool_contract_result", `String receipt.tool_contract_result);
      ( "tool_surface",
        `Assoc
          [
            ("turn_lane", `String receipt.tool_surface.turn_lane);
            ("tool_surface_class", `String receipt.tool_surface.tool_surface_class);
            ("tool_requirement", `String receipt.tool_surface.tool_requirement);
            ("visible_tool_count", `Int receipt.tool_surface.visible_tool_count);
            ("tool_gate_enabled", `Bool receipt.tool_surface.tool_gate_enabled);
            ( "tool_surface_fallback_used",
              `Bool receipt.tool_surface.tool_surface_fallback_used );
          ] );
      ( "sandbox",
        `Assoc
          [
            ("kind", `String receipt.sandbox_kind);
            ( "sandbox_root",
              match receipt.sandbox_root with
              | Some value -> `String value
              | None -> `Null );
            ("network_mode", `String receipt.network_mode);
          ] );
      ( "approval",
        `Assoc
          [
            ( "profile",
              match receipt.approval_profile with
              | Some value -> `String value
              | None -> `Null );
            ("derived", `Bool receipt.approval_profile_derived);
          ] );
      ( "cascade",
        `Assoc
          [
            ("name", `String receipt.cascade_name);
            ( "selected_model",
              match receipt.cascade_selected_model with
              | Some value -> `String value
              | None -> `Null );
            ("attempt_count", `Int receipt.cascade_attempt_count);
            ("fallback_applied", `Bool receipt.cascade_fallback_applied);
            ("outcome", `String receipt.cascade_outcome);
            ("degraded_retry_applied", `Bool receipt.degraded_retry_applied);
            ( "degraded_retry_cascade",
              match receipt.degraded_retry_cascade with
              | Some value -> `String value
              | None -> `Null );
            ( "fallback_reason",
              match receipt.fallback_reason with
              | Some value -> `String value
              | None -> `Null );
            ( "rotation_attempts",
              `List
                (List.map cascade_rotation_attempt_to_json
                   receipt.cascade_rotation_attempts) );
          ] );
      ( "stop_reason",
        match receipt.stop_reason with
        | Some value -> `String value
        | None -> `Null );
      ("error", error_json);
      ("started_at", `String receipt.started_at);
      ("ended_at", `String receipt.ended_at);
    ]

let append (config : Coord.config) (receipt : t) =
  let store =
    Keeper_types_support.keeper_execution_receipt_store config
      receipt.keeper_name
  in
  Dated_jsonl.append store (to_json receipt)

let latest_json (config : Coord.config) keeper_name =
  let store =
    Keeper_types_support.keeper_execution_receipt_store config keeper_name
  in
  match Dated_jsonl.read_recent store 1 with
  | [ json ] -> Some json
  | _ -> None

let latest_json_by_keeper (config : Coord.config) keeper_names =
  keeper_names
  |> List.filter_map (fun keeper_name ->
         match latest_json config keeper_name with
         | Some json -> Some (keeper_name, json)
         | None -> None)
