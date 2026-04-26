type tool_surface =
  { turn_lane : string
  ; tool_surface_class : string
  ; tool_requirement : string
  ; visible_tool_count : int
  ; tool_gate_enabled : bool
  ; tool_surface_fallback_used : bool
  ; required_tools : string list
  ; missing_required_tools : string list
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

let receipt_duration_ms receipt =
  match
    Types.parse_iso8601_opt receipt.started_at,
    Types.parse_iso8601_opt receipt.ended_at
  with
  | Some started_at, Some ended_at ->
    max 0.0 ((ended_at -. started_at) *. 1000.0)
  | _ -> 0.0

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
  let tool_contract_result =
    String.lowercase_ascii receipt.tool_contract_result
  in
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
    && (List.mem tool_contract_result
          [
            "violated";
            "unknown";
            "needs_execution_progress";
            "missing_required_tool_use";
            "passive_only";
            "claim_only_after_owned_task";
            "tool_surface_mismatch";
            "no_tool_capable_provider";
          ]
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
  let runtime_contract =
    Keeper_runtime_contract.runtime_contract_json_from_fields
      ~keeper_name:receipt.keeper_name
      ~agent_name:receipt.agent_name
      ~trace_id:receipt.trace_id
      ~session_id:receipt.trace_id
      ~generation:receipt.generation
      ?keeper_turn_id:receipt.turn_count
      ?task_id:receipt.current_task_id
      ~goal_ids:receipt.goal_ids
      ~sandbox_profile:receipt.sandbox_kind
      ?sandbox_root:receipt.sandbox_root
      ~network_mode:receipt.network_mode
      ?approval_mode:receipt.approval_profile
      ~tool_surface_class:receipt.tool_surface.tool_surface_class
      ~visible_tool_count:receipt.tool_surface.visible_tool_count
      ~required_tools:receipt.tool_surface.required_tools
      ~missing_required_tools:receipt.tool_surface.missing_required_tools
      ?model:receipt.model_used
      ~cascade_profile:receipt.cascade_name
      ()
  in
  let action_radius =
    Keeper_runtime_contract.action_radius_json
      ~tool_name:"keeper_turn"
      ~input:
        (`Assoc
           [
             ("action", `String "run_turn");
             ("target_kind", `String "keeper");
             ("target_path", string_opt_json receipt.sandbox_root);
           ])
      ~success:(String.equal receipt.outcome "ok")
      ~duration_ms:(receipt_duration_ms receipt)
      ?error:receipt.error_message
      ~sandbox_target:receipt.sandbox_kind
      ()
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
      ("runtime_contract", runtime_contract);
      ("action_radius", action_radius);
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
            ("required_tools", list_json receipt.tool_surface.required_tools);
            ( "missing_required_tools",
              list_json receipt.tool_surface.missing_required_tools );
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

(* Operator broadcast hook (#fleet-stall 2026-04-26): operator_disposition
   was a derived display field — emitted nowhere. A pause_human/alert_exhausted
   verdict therefore had no transition out: dashboard turned a chip red, but
   no event reached operators and no supervisor handoff fired. We now emit a
   structured "keeper.operator_broadcast_required" activity event so the gate
   verdict becomes addressable instead of cosmetic. *)
let needs_operator_broadcast = function
  | "pause_human" | "alert_exhausted" | "unknown" -> true
  | _ -> false

let emit_operator_broadcast config (receipt : t) ~disposition ~reason =
  let payload =
    `Assoc
      [ "schema", `String "keeper.operator_broadcast_required.v1"
      ; "keeper_name", `String receipt.keeper_name
      ; "agent_name", `String receipt.agent_name
      ; "trace_id", `String receipt.trace_id
      ; "generation", `Int receipt.generation
      ; "disposition", `String disposition
      ; "disposition_reason", `String reason
      ; "outcome", `String receipt.outcome
      ; "terminal_reason_code", `String receipt.terminal_reason_code
      ; "cascade_name", `String receipt.cascade_name
      ; "cascade_outcome", `String receipt.cascade_outcome
      ; "tool_contract_result", `String receipt.tool_contract_result
      ; ( "error_kind"
        , match receipt.error_kind with
          | Some v -> `String v
          | None -> `Null )
      ; ( "error_message"
        , match receipt.error_message with
          | Some v -> `String v
          | None -> `Null )
      ; "ended_at", `String receipt.ended_at
      ]
  in
  let event =
    Activity_graph.emit config
      ~actor:{ Activity_graph.kind = "agent"; id = receipt.agent_name }
      ~kind:"keeper.operator_broadcast_required"
      ~payload
      ()
  in
  Log.Keeper.info
    "%s: operator_broadcast_required emitted disposition=%s reason=%s seq=%d"
    receipt.keeper_name disposition reason event.seq

let append (config : Coord.config) (receipt : t) =
  let store =
    Keeper_types_support.keeper_execution_receipt_store config
      receipt.keeper_name
  in
  Dated_jsonl.append store (to_json receipt);
  let disposition, reason = operator_disposition receipt in
  if needs_operator_broadcast disposition then
    try emit_operator_broadcast config receipt ~disposition ~reason with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      (* fail-closed: log loud, do not silently swallow. The append itself
         has already persisted the receipt; the broadcast failure is its
         own diagnostic that watchdogs/log alerts will pick up. *)
      Log.Keeper.error
        "%s: operator_broadcast_required EMIT FAILED disposition=%s \
         reason=%s exn=%s"
        receipt.keeper_name disposition reason (Printexc.to_string exn)

(* Watchdog-driven broadcast (#fleet-stall 2026-04-26 Step 3): emitted by a
   supervisor-side fiber when a Running keeper has not produced a turn for
   longer than the stale threshold. This is the path that catches the
   "KSM=Running but no live turn" failure mode where the heartbeat fiber is
   blocked on a long call and would otherwise never produce a receipt. *)
let emit_stale_keeper_broadcast config
    ~keeper_name ~agent_name ~trace_id ~generation
    ~stale_seconds ~last_turn_ts =
  let payload =
    `Assoc
      [ "schema", `String "keeper.operator_broadcast_required.v1"
      ; "keeper_name", `String keeper_name
      ; "agent_name", `String agent_name
      ; "trace_id", `String trace_id
      ; "generation", `Int generation
      ; "disposition", `String "stalled"
      ; "disposition_reason"
      , `String (Printf.sprintf "stale_turn_%.0fs" stale_seconds)
      ; "stale_seconds", `Float stale_seconds
      ; "last_turn_ts", `Float last_turn_ts
      ; "source", `String "watchdog"
      ]
  in
  let event =
    Activity_graph.emit config
      ~actor:{ Activity_graph.kind = "watchdog"; id = keeper_name }
      ~kind:"keeper.operator_broadcast_required"
      ~payload
      ()
  in
  Log.Keeper.error
    "%s: stale_keeper_broadcast emitted last_turn=%.0fs ago seq=%d"
    keeper_name stale_seconds event.seq

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
