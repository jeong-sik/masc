(** Canonical immutable values shared by usage decoding and observation reduction. *)

type window_kind =
  | Five_hour
  | Seven_day
  | Duration_minutes of int
  | Provider_label of string

type utilization =
  | Fraction of float
  | Percent of int
  | Usd of { used : float; limit : float option }

type source =
  | Claude_code_rate_limit_event
  | Codex_account_rate_limits_updated
  | Codex_account_rate_limits_read
  | Openrouter_key_read
  | Zai_quota_limit_read
  | Kimi_coding_usages_read
  | Ollama_balance_read
  | Antigravity_usage_read
  | Muse_subscription_usage

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
