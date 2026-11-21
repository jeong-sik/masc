(** Canonical immutable values shared by usage decoding and observation reduction. *)

module Positive_minutes = struct
  type t = int

  let of_int n = if n > 0 then Some n else None
  let to_int n = n
  let equal = Int.equal
  let compare = Int.compare
end

type window_kind =
  | Five_hour
  | Seven_day
  | Duration_minutes of Positive_minutes.t
  | Provider_label of string

type utilization =
  | Fraction of float
  | Percent of int
  | Usd of { used : float; limit : float option }
  | Credit_balance of { currency : string; total : float option; remaining : float }
  | Credit_unlimited
  | Credit_retracted

type source =
  | Claude_code_rate_limit_event
  | Codex_account_rate_limits_updated
  | Codex_account_rate_limits_read
  | Openrouter_key_read
  | Openrouter_credits_read
  | Zai_quota_limit_read
  | Kimi_coding_usages_read
  | Ollama_balance_read
  | Antigravity_usage_read

type window_role =
  | Gates_model_calls
  | Counts_other_use
  | Unclassified_limit

type window =
  { limit_id : string option
  ; kind : window_kind
  ; role : window_role
  ; utilization : utilization
  ; resets_at : int option
  }

type report =
  { source : source
  ; windows : window list
  }

type recorded =
  { window : window
  ; source : source
  ; observed_at : float
  }

type scope_state =
  | Not_reported_since_start
  | Reported_no_windows of { source : source; observed_at : float }
  | Reported of recorded * recorded list

type report_shape = Complete_snapshot | Sparse_update
