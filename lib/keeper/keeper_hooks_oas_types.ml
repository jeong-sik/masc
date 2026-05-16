(** Keeper_hooks_oas_types — pure cost_status verdict ADT + converters
    extracted from Keeper_hooks_oas (2762 LoC godfile).

    See keeper_hooks_oas_types.mli for rationale and contract. *)

let outcome_ok = "ok"
let outcome_error = "error"

(** Keeper-facing telemetry uses a neutral runtime lane.  Concrete
    provider/model identity belongs to OAS and lower-level cascade adapters. *)
let runtime_lane_label = "runtime"

let runtime_lane_of_model (_model : string) : string = runtime_lane_label

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
let cost_label_usage_missing = "usage_missing"
let cost_label_usage_untrusted = "usage_untrusted"
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
  else if not usage_trusted then Cost_usage_untrusted
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
  let thinking_blocks = ref 0 in
  let thinking_chars = ref 0 in
  let redacted_thinking_blocks = ref 0 in
  List.iter
    (function
      | Agent_sdk.Types.Thinking { content; _ } ->
          incr thinking_blocks;
          thinking_chars := !thinking_chars + String.length content
      | Agent_sdk.Types.RedactedThinking _ -> incr redacted_thinking_blocks
      | _ -> ())
    content;
  let thinking_kind =
    match !thinking_blocks > 0, !redacted_thinking_blocks > 0 with
    | false, false -> "none"
    | true, false -> "thinking"
    | false, true -> "redacted"
    | true, true -> "mixed"
  in
  { thinking_present = !thinking_blocks > 0 || !redacted_thinking_blocks > 0
  ; thinking_blocks = !thinking_blocks
  ; thinking_chars = !thinking_chars
  ; redacted_thinking_blocks = !redacted_thinking_blocks
  ; thinking_kind
  }

type pr_review_action_metric_event = {
  action : string;
  pr_number : int option;
  comment_id : int option;
  success : bool;
  route_via : string option;
  credential : Yojson.Safe.t option;
  identity_attestation : Yojson.Safe.t option;
}

type pr_work_action_metric_event = {
  work_action : string;
  work_source : string;
  work_ref : string option;
  pr_url : string option;
  command : string option;
  success : bool;
  route_via : string option;
}

let normalize_pr_review_action raw =
  let trimmed = String.trim raw |> String.uppercase_ascii in
  match trimmed with
  | "COMMENT" | "APPROVE" | "REQUEST_CHANGES" | "REPLY" -> Some trimmed
  | _ -> None

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
