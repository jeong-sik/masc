(** Pure usage projections for provider quota windows/history and Keeper
    coverage. Unknown wire variants and invalid cache combinations remain
    errors; absent sums stay absent. No network, clock or UI dependency. *)

type provider_usage_window_kind =
  | Window_five_hour
  | Window_seven_day
  | Window_duration_minutes of int
      (** A window length the server has no name for. *)
  | Window_provider_label of string
      (** A label the provider gave the window, kept as written. *)

(** The usage in the unit the provider reported it in. Not clamped. *)
type provider_usage_utilization =
  | Utilization_fraction of float  (** [0.67] is 67 %. *)
  | Utilization_percent of int
  | Utilization_usd of { used : float; limit : float option }
      (** A reported USD credit amount; [None] means no key cap. *)

(** What a window limits, as the server's decoder classified it from the
    provider's own shape. *)
type provider_usage_window_role =
  | Role_gates_model_calls
      (** Spending it refuses model calls on the account. *)
  | Role_counts_other_use
      (** It counts something a model call does not need, e.g. Z.AI's
          TIME_LIMIT (MCP and tool calls). *)
  | Role_unclassified_limit
      (** A limit the server's decoder does not know. *)

type provider_usage_window = {
  puw_limit_id : string option;
  puw_kind : provider_usage_window_kind;
  puw_role : provider_usage_window_role;
  puw_utilization : provider_usage_utilization;
  puw_resets_at : float option;  (** Epoch seconds, as reported. *)
  puw_observed_at : float;  (** When the server heard this report. *)
}

(** A complete report with no windows is distinct from a missing report. *)
type provider_usage_state =
  | Account_not_reported_since_start
  | Account_reported_no_windows of { observed_at : float; source : string }
  | Account_reported of provider_usage_window * provider_usage_window list

(** A provider table that bills to the account. *)
type provider_usage_provider = {
  pup_id : string;  (** The [providers.<id>] key. *)
  pup_display_name : string;
      (** The table's [display-name]; the id when the table names none. *)
}

type provider_usage_account = {
  pua_scope : string;  (** The quota scope, as [quota_scope] on runtime rows. *)
  pua_scope_id : string;
      (** The server's opaque id for the scope, the one its usage history
          points carry as [scope_id]. Compared, never recomputed. *)
  pua_providers : provider_usage_provider list;
  pua_state : provider_usage_state;
}

type provider_usage_windows = {
  puws_since : float;  (** Server process start: the table's first moment. *)
  puws_accounts : provider_usage_account list;
}

type provider_usage_history_point = {
  puhp_scope_id : string;
  puhp_kind : string;
  puhp_limit_id : string option;
  puhp_unit : provider_usage_utilization;
  puhp_observed_at : float;
}

type provider_usage_empty_report = {
  puhe_scope_id : string;
  puhe_observed_at : float;
}

type provider_usage_history = {
  puh_days : int;
  puh_generated_at : float;
  puh_unreadable_reports : int;
      (** Stored reports in the window the server could not read and left
          out. A gap they leave is unknown, not a quiet day. *)
  puh_points : provider_usage_history_point list;
  puh_reported_no_windows : provider_usage_empty_report list;
}

val decode_provider_usage_history :
  Yojson.Safe.t -> (provider_usage_history, string) result

val decode_provider_usage_windows :
  Yojson.Safe.t -> (provider_usage_windows, string) result
(** Strict decoder for the [provider_usage_windows_since] and
    [provider_usage_windows] members of [GET /api/v1/runtime/resolved]. An
    unknown [state], window [kind], window [role] or utilization [unit] is an
    error, as is a reported account without windows or an unreported one with
    windows. *)

type keeper_usage_coverage =
  | Keeper_usage_complete
  | Keeper_usage_partial of int
  | Keeper_usage_failed of string

type keeper_usage_row = {
  kur_name : string;
  kur_turn_samples : int;
  kur_tokens : int option;
  kur_cost_usd : float option;
  kur_tokens_reported : int;
  kur_tokens_missing : int;
  kur_cost_reported : int;
  kur_cost_missing : int;
  kur_coverage : keeper_usage_coverage;
}

type keeper_usage_freshness =
  | Keeper_usage_fresh
  | Keeper_usage_stale of { age_s : float; last_error : string option }

type keeper_usage_window =
  | Keeper_usage_loading
  | Keeper_usage_window of {
      kuw_generated_at : float;
      kuw_window_minutes : int;
      kuw_rows : keeper_usage_row list;
      kuw_freshness : keeper_usage_freshness;
    }

val decode_keeper_usage_window :
  Yojson.Safe.t -> (keeper_usage_window, string) result
(** Decode the coverage-bearing [/api/v1/dashboard/keeper-costs] projection.
    A null sum stays absent, and a loading placeholder never reads as zero. *)
