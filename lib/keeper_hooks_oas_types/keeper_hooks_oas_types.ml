(** Keeper_hooks_oas_types — pure cost_status verdict ADT + converters
    extracted from Keeper_hooks_oas (2762 LoC godfile).

    See keeper_hooks_oas_types.mli for rationale and contract. *)

let outcome_ok = "ok"
let outcome_error = "error"

(** Keeper-facing telemetry uses a neutral runtime lane.  Concrete
    provider/model identity belongs to OAS and lower-level runtime adapters.
    RFC-0132 PR-2: telemetry lane label = external boundary; redact via SSOT. *)
let runtime_lane_label = Boundary_redaction.runtime_lane_label

let runtime_lane_of_model (_model : string) : string = runtime_lane_label

(** Otel_metric_store + JSON label keys used across keeper_hooks_oas.ml call sites.
    Exposed via mli so the rest of the godfile keeps referencing them through
    `include Keeper_hooks_oas_types`. *)
let label_keeper = "keeper"
let label_callback = "callback"
let label_tool = "tool"
let label_source = "source"
let label_alias = "alias"
let label_surface = "surface"
let label_shape = "shape"
let label_model = "model"
let label_provider = "provider"
let label_provider_kind = "provider_kind"
let label_status = "status"
let label_site = "site"
let label_reason = "reason"
let label_outcome = "outcome"
let label_severity = "severity"
let label_decision = "decision"
let label_stop_reason = "stop_reason"
let label_keeper_name = "keeper_name"
let label_channel = "channel"

(** JSON field-key constants used across keeper_hooks_oas.ml. *)
let key_agent = "agent"
let key_task_id = "task_id"
let key_input_tokens = "input_tokens"
let key_output_tokens = "output_tokens"
let key_cost_usd = "cost_usd"
let key_cost_status = "cost_status"
let key_cost_status_reason = "cost_status_reason"
let key_cost_usd_source = "cost_usd_source"
let key_usage_missing = "usage_missing"
let key_timestamp = "timestamp"
let key_raw_input_tokens = "raw_input_tokens"
let key_raw_output_tokens = "raw_output_tokens"
let key_raw_cost_usd = "raw_cost_usd"
let key_reasoning_tokens = "reasoning_tokens"
let key_cache_n = "cache_n"
let key_prompt_per_second = "prompt_per_second"
let key_provider_tokens_per_second = "provider_tokens_per_second"
let key_hw_decode_tokens_per_second = "hw_decode_tokens_per_second"
let key_peak_memory_gb = "peak_memory_gb"
let key_request_latency_ms = "request_latency_ms"
let key_tokens_per_second = "tokens_per_second"
let key_status = "status"
let key_reason = "reason"
let key_provider = "provider"
let key_model = "model"
let key_source = "source"
let key_type = "type"
let key_turn = "turn"
let key_model_used = "model_used"
let key_has_state_block = "has_state_block"
let key_tool_calls_made = "tool_calls_made"
let key_total_turns = "total_turns"
let key_scope = "scope"
let key_slots = "slots"
let key_max_cost_usd = "max_cost_usd"
let key_ts = "ts"
let key_ts_unix = "ts_unix"
let key_name = "name"
let key_generation = "generation"
let key_active = "active"
let key_via = "via"
let key_route_via = "route_via"
let key_metric_event = "metric_event"
let key_agent_name = "agent_name"
let key_tool_name = "tool_name"
let key_tool_call_count = "tool_call_count"
let key_tools_used = "tools_used"
let key_duration_ms = "duration_ms"
let key_channel = "channel"
let key_error = "error"

(** Callback name labels used as Otel_metric_store + log identifiers. *)
let callback_label_after_turn_sse_broadcast = "after_turn_sse_broadcast"
let callback_label_post_tool_log_write = "post_tool_log_write"
let callback_label_on_tool_executed = "on_tool_executed"
let callback_label_on_error = "on_error"
let callback_label_on_tool_error = "on_tool_error"

type cost_status =
  | Cost_reported
  | Cost_known_free
  | Cost_no_tokens
  | Cost_usage_missing
  | Cost_usage_untrusted
  | Cost_runtime_unknown
  | Cost_oas_cost_unreported

let cost_label_reported = "reported"
let cost_label_known_free = "known_free"
let cost_label_no_tokens = "no_tokens"
let cost_label_usage_missing = "missing_usage"
let cost_label_usage_untrusted = "untrusted_usage"
let cost_label_runtime_unknown = "runtime_unknown"
let cost_label_oas_cost_unreported = "oas_cost_unreported"

let cost_reason_reported = "oas_reported_cost"
let cost_reason_known_free = "known_structurally_unmetered_or_zero_price"
let cost_reason_no_tokens = "no_billable_tokens"
let cost_reason_usage_missing = "usage_missing"
let cost_reason_usage_untrusted = "usage_untrusted"
let cost_reason_runtime_unknown = "runtime_unknown"
let cost_reason_oas_cost_unreported = "oas_cost_unreported"

let cost_status_to_string = function
  | Cost_reported -> cost_label_reported
  | Cost_known_free -> cost_label_known_free
  | Cost_no_tokens -> cost_label_no_tokens
  | Cost_usage_missing -> cost_label_usage_missing
  | Cost_usage_untrusted -> cost_label_usage_untrusted
  | Cost_runtime_unknown -> cost_label_runtime_unknown
  | Cost_oas_cost_unreported -> cost_label_oas_cost_unreported

let cost_status_reason = function
  | Cost_reported -> cost_reason_reported
  | Cost_known_free -> cost_reason_known_free
  | Cost_no_tokens -> cost_reason_no_tokens
  | Cost_usage_missing -> cost_reason_usage_missing
  | Cost_usage_untrusted -> cost_reason_usage_untrusted
  | Cost_runtime_unknown -> cost_reason_runtime_unknown
  | Cost_oas_cost_unreported -> cost_reason_oas_cost_unreported

let cost_status_for_event
    ~(runtime_unknown : bool)
    ~(runtime_unmetered : bool)
    ~(usage_missing : bool)
    ~(usage_trusted : bool)
    ~(input_tokens : int)
    ~(output_tokens : int)
    ~(cost_usd : float) =
  if usage_missing then Cost_usage_missing
  (* token⊥cost: an untrusted *token count* does not gate the provider's
     authoritative cost_usd. A positive cost_usd is accounted (Cost_reported)
     even when token usage is untrusted; only zero/absent cost on an untrusted
     turn keeps the Cost_usage_untrusted label. *)
  else if (not usage_trusted) && not (cost_usd > 0.0) then Cost_usage_untrusted
  else if cost_usd > 0.0 then Cost_reported
  else if input_tokens <= 0 && output_tokens <= 0 then Cost_no_tokens
  else if runtime_unmetered then Cost_known_free
  else if runtime_unknown then Cost_runtime_unknown
  else Cost_oas_cost_unreported

let redacts_inference_telemetry_key key =
  match String.lowercase_ascii (String.trim key) with
  | "provider"
  | "provider_id"
  | "provider_kind"
  | "provider_name"
  | "model"
  | "model_id"
  | "canonical_model_id"
  | "default_model"
  | "discovered_model"
  | "system_fingerprint" -> true
  | _ -> false

let rec redact_inference_telemetry_json = function
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
              if redacts_inference_telemetry_key key then (key, `Null)
              else (key, redact_inference_telemetry_json value))
           fields)
  | `List values -> `List (List.map redact_inference_telemetry_json values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value ->
      value

let inference_telemetry_to_runtime_json telemetry =
  telemetry
  |> Agent_sdk.Types.inference_telemetry_to_yojson
  |> redact_inference_telemetry_json

let default_context_max = 0

let context_max_of_telemetry
    (telemetry : Agent_sdk.Types.inference_telemetry option) =
  match telemetry with
  | Some { effective_context_window = Some n; _ } when n > 0 -> n
  | _ -> default_context_max

type thinking_log_summary =
  { thinking_present : bool
  ; thinking_blocks : int
  ; thinking_chars : int
  ; redacted_thinking_blocks : int
  ; thinking_kind : string
  }

let summarize_thinking_blocks content =
  (* F2 canonical projection consumption: delegate block counting to the OAS
     [Response_shape.summarize_blocks] (exhaustive per-variant fold) instead of
     re-iterating with a [_ -> ()] catch-all that silently drops a new
     thinking-bearing content_block variant. MASC keeps only the policy shaping
     (thinking_present + thinking_kind classifier). The leading qualified field
     anchors the pattern to [Response_shape.t] to disambiguate the shared
     thinking_* field names. *)
  let { Agent_sdk.Response_shape.thinking_blocks
      ; thinking_chars
      ; redacted_thinking_blocks
      ; _
      } =
    Agent_sdk.Response_shape.summarize_blocks content
  in
  let thinking_kind =
    match thinking_blocks > 0, redacted_thinking_blocks > 0 with
    | false, false -> "none"
    | true, false -> "thinking"
    | false, true -> "redacted"
    | true, true -> "mixed"
  in
  { thinking_present = thinking_blocks > 0 || redacted_thinking_blocks > 0
  ; thinking_blocks
  ; thinking_chars
  ; redacted_thinking_blocks
  ; thinking_kind
  }

type tool_execution_summary =
  { tool_name : string
  ; provider : string
  ; outcome : string
  ; duration_ms : float
  }

let tool_execution_summary ~tool_name ~model ~success ~duration_ms :
    tool_execution_summary =
  { tool_name
  ; provider = runtime_lane_of_model model
  ; outcome = if success then outcome_ok else outcome_error
  ; duration_ms = max 0.0 duration_ms
  }

let usage_has_tokens (usage : Agent_sdk.Types.api_usage) =
  usage.input_tokens > 0
  || usage.output_tokens > 0
  || usage.cache_creation_input_tokens > 0
  || usage.cache_read_input_tokens > 0

let is_keeper_board_write_tool_name tool_name =
  Keeper_tool_name.is_board_write_surface_name tool_name

let current_keeper_model _meta =
  runtime_lane_label

let stop_reason_to_label = Agent_sdk.Types.stop_reason_to_metric_label
let stop_reason_label_end_turn = stop_reason_to_label Agent_sdk.Types.EndTurn
let stop_reason_label_tool_use = stop_reason_to_label Agent_sdk.Types.StopToolUse
let stop_reason_label_max_tokens = stop_reason_to_label Agent_sdk.Types.MaxTokens
let stop_reason_label_stop_sequence =
  stop_reason_to_label Agent_sdk.Types.StopSequence

let stop_reason_label_unknown =
  stop_reason_to_label (Agent_sdk.Types.Unknown "")

(* F4 canonical projection consumption: delegate to OAS instead of re-spelling
   the api_usage record literal (SSOT — OAS owns the zero marker). *)
let zero_usage = Agent_sdk.Types.zero_api_usage

let telemetry_has_canonical_model_id
    (telemetry : Agent_sdk.Types.inference_telemetry option) =
  match telemetry with
  | Some { canonical_model_id = Some id; _ } -> String.trim id <> ""
  | Some _ | None -> false

let canonical_model_id_of_telemetry
    (telemetry : Agent_sdk.Types.inference_telemetry option) =
  match telemetry with
  | Some { canonical_model_id = Some id; _ } ->
      let trimmed = String.trim id in
      if trimmed <> "" then Some trimmed else None
  | Some _ | None -> None

let is_runtime_selector_alias model =
  let trimmed = String.trim model |> String.lowercase_ascii in
  let leaf =
    match String.rindex_opt trimmed ':' with
    | None -> trimmed
    | Some idx when idx >= String.length trimmed - 1 -> ""
    | Some idx ->
        String.sub trimmed (idx + 1) (String.length trimmed - idx - 1)
        |> String.trim
  in
  String.equal leaf "auto"

let ms_per_second = 1000.0

let cost_source_unmetered_provider = "unmetered_provider"
let cost_source_computed = "computed"

let oas_reported_cost (usage : Agent_sdk.Types.api_usage) : float =
  match usage.cost_usd with
  | Some cost when cost > 0.0 -> cost
  | Some _ -> 0.0
  | None -> 0.0
