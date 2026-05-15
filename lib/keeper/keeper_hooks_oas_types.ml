(** Keeper_hooks_oas_types — pure cost_status verdict ADT + converters
    extracted from Keeper_hooks_oas (2762 LoC godfile).

    See keeper_hooks_oas_types.mli for rationale and contract. *)

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
