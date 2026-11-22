(** Runtime & Telemetry domain sub-store: Quotas & Subscription Windows vs API
    [Credit_balance], Efficiency & Prompt Cache % + Dual Token Velocity, fast
    [/runtime/resolved] Failover Lanes isolated from async [/runtime-probe],
    Exact lanes, Fusion runs + launch draft, and Tools/Connectors/Browser/
    Clients.

    Strictly observation-only and Provider/Model-Free. *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_map : Map.S with type key = string

type fusion_draft = {
  keeper : string option;
  prompt : string;
  preset : string option;
  topology : Wire_runtime.fusion_topology option;
  web_tools : bool;
  submitting : bool;
}

type partitioned_accounts = {
  exhausted_and_credits : Wire_runtime.account_usage list;
  active_subscriptions : Wire_runtime.account_usage list;
  unreported : Wire_runtime.account_usage list;
}

type velocity_series_kind =
  | Velocity_tokens of (float * float * float) list
      (** [(ts_start, input_plus_cache_tok, output_tok)] chronological buckets *)
  | Velocity_calls_and_spend of (float * float * float) list
      (** [(ts_start, entry_count, total_cost_usd)] chronological buckets *)
  | Velocity_tool_calls_and_p95 of (float * float * float) list
      (** [(ts_start, call_count, p95_ms)] chronological buckets *)
  | Velocity_empty

type keeper_spend_row = {
  keeper : string;
  company : string;
  calls : int;
  turns : int;
  input_tokens : int;
  output_tokens : int;
  cache_hit_pct : float Observed.t;
  cost_usd : float;
  cost_per_turn_usd : float option;
}

type company_spend_row = {
  company : string;
  keeper_count : int;
  calls : int;
  turns : int;
  cost_usd : float;
}

type company_spend_group = {
  company : string;
  total_cost_usd : float;
  members : keeper_spend_row list;
}

type t = {
  active_tab : Nav.runtime_tab;
  usage_windows : Wire_runtime.provider_usage_windows Observed.t;
  usage_history : Wire_runtime.provider_usage_history Observed.t;
  keeper_costs : Wire_runtime.keeper_costs_window Observed.t;
  efficiency : Wire_runtime.efficiency_month Observed.t;
  models_metrics : Wire_runtime.models_metrics_snapshot Observed.t;
  runtime_metrics : Wire_runtime.runtime_metrics_snapshot Observed.t;
  runtime_resolved : Wire_runtime.runtime_resolved_snapshot Observed.t;
  runtime_probe : Wire_runtime.runtime_probe_snapshot Observed.t;
  exact_lane_runs : Wire_runtime.exact_lane_run list Observed.t;
  fusion_runs : Wire_runtime.fusion_run list Observed.t;
  fusion_launch_draft : fusion_draft;
  tool_series : Wire_runtime.tool_series Observed.t;
  tools_catalog : Wire_runtime.tool_summary list Observed.t;
  connectors : Wire_runtime.connector_row list Observed.t;
  browser_lane : Wire_runtime.browser_lane_status Observed.t;
  mcp_clients : Wire_runtime.mcp_client_row list Observed.t;
  keeper_companies : string String_map.t;
  show_outside_lane_probes : bool;
  show_unreported_accounts : bool;
  selected_index : int;
  scroll_offset : int;
  filter_query : string;
}

val empty_fusion_draft : fusion_draft
val empty : t

val set_tab : Nav.runtime_tab -> t -> t
val cycle_tab : Keymap.cycle_dir -> t -> t

val apply_usage_windows :
  observed_at:Clock.Mono.t -> Wire_runtime.provider_usage_windows -> t -> t
val apply_usage_history :
  observed_at:Clock.Mono.t -> Wire_runtime.provider_usage_history -> t -> t
val apply_keeper_costs :
  observed_at:Clock.Mono.t -> Wire_runtime.keeper_costs_window -> t -> t
val apply_efficiency :
  observed_at:Clock.Mono.t -> Wire_runtime.efficiency_month -> t -> t
val apply_models_metrics :
  observed_at:Clock.Mono.t -> Wire_runtime.models_metrics_snapshot -> t -> t
val apply_runtime_metrics :
  observed_at:Clock.Mono.t -> Wire_runtime.runtime_metrics_snapshot -> t -> t
val apply_runtime_resolved :
  observed_at:Clock.Mono.t -> Wire_runtime.runtime_resolved_snapshot -> t -> t
val apply_runtime_probe :
  observed_at:Clock.Mono.t -> Wire_runtime.runtime_probe_snapshot -> t -> t
val apply_exact_lane_runs :
  observed_at:Clock.Mono.t -> Wire_runtime.exact_lane_run list -> t -> t
val apply_fusion_runs :
  observed_at:Clock.Mono.t -> Wire_runtime.fusion_run list -> t -> t
val apply_tool_series :
  observed_at:Clock.Mono.t -> Wire_runtime.tool_series -> t -> t
val apply_tools_catalog :
  observed_at:Clock.Mono.t -> Wire_runtime.tool_summary list -> t -> t
val apply_connectors :
  observed_at:Clock.Mono.t -> Wire_runtime.connector_row list -> t -> t
val apply_browser_lane :
  observed_at:Clock.Mono.t -> Wire_runtime.browser_lane_status -> t -> t
val apply_mcp_clients :
  observed_at:Clock.Mono.t -> Wire_runtime.mcp_client_row list -> t -> t

val active_and_outside_probes :
  t -> Wire_runtime.provider_probe_row list * Wire_runtime.provider_probe_row list
(** Partition async runtime-probe rows strictly by active failover lanes so
    outside-lane failures never pollute active-lane health headers. *)

val toggle_outside_lane_probes : t -> t
val toggle_unreported_accounts : t -> t
val set_show_unreported_accounts : bool -> t -> t

val partition_accounts : t -> partitioned_accounts
(** Signal-first 3-tier account partition for [Quotas & Credits]:
    1. [exhausted_and_credits] (Exhausted first, then metered USD balances by
       lowest remaining ratio / amount),
    2. [active_subscriptions] (sorted by highest rolling utilization descending),
    3. [unreported] (collapsed by default behind [show_unreported_accounts]). *)

val visible_credit_accounts : t -> Wire_runtime.account_usage list
(** Ordered accounts currently expanded in [Quotas & Credits] right pane. *)

val is_unreported_toggle_row_selected : t -> bool
(** [true] when [selected_index] points to the collapsible unreported summary
    footer row in [Quotas & Credits]. *)

val account_display_name :
  ?lang:Say.lang -> t -> Wire_runtime.account_usage -> string
(** Resolve clean human provider alias using loaded [runtime_resolved.runtimes]
    and full account list for collision-only disambiguation. *)

val effective_cache_hit_pct : t -> float Observed.t
(** Authoritative 24h/fleet prompt cache hit % from [runtime_metrics],
    [models_metrics], or [efficiency] (first available reported value). *)

type spend_24h_source =
  | Spend_provider_24h
  | Spend_keeper_turns_24h
  | Spend_unreported

type spend_24h_breakdown = {
  source : spend_24h_source;
  total_usd : float Observed.t;
  provider_usd : float Observed.t;
  keeper_attributed_usd : float Observed.t;
  system_unattributed_usd : float option;
}

type spend_table_window =
  | Spend_window_mtd of { month : string; days_covered : int }
  | Spend_window_month_complete of { month : string; days_covered : int }
  | Spend_window_24h of { window_minutes : int }
  | Spend_window_none

val effective_spend_24h_usd : t -> float Observed.t
(** Authoritative 24h USD spend from [models_metrics], [runtime_metrics], or
    summed [keeper_costs]. *)

val spend_24h_breakdown : t -> spend_24h_breakdown
(** Typed 24h spend provenance separating provider-wide inference spend
    ([/api/v1/models/metrics]) from keeper-turn attributed spend
    ([/api/v1/dashboard/keeper-costs]) and the unattributed system delta. *)

val keeper_spend_table_window : t -> spend_table_window
(** Authoritative time-window provenance of {!keeper_spend_rows} so monthly MTD
    ([/api/v1/keeper-efficiency]) is never mislabeled as 24h. *)

val tool_series_totals : t -> (int * int * float option) option
(** [(total_calls, total_failures, latest_or_max_p95_ms)] across the 24h tool
    series buckets. *)

val cache_hit_series_24h : t -> (float * float option) list
(** Chronological hourly [(ts_start, cache_hit_pct)] series from
    [models_metrics] (falling back to [runtime_metrics]). *)

val velocity_series_24h : t -> velocity_series_kind
(** Chronological 24h dual-inverted throughput series for [Efficiency & Spend]:
    prefers real hourly input/output tokens when present, falling back cleanly
    to hourly calls & USD spend from [models_metrics], then hourly tool calls &
    p95 latency from [tool_series]. *)

val sync_keeper_companies : Wire_fleet.keeper_summary list -> t -> t
(** Sync keeper -> resolved company lookup table from the authoritative fleet
    roster so Efficiency & Spend grouping matches Keepers & Pulse. *)

val keeper_costs_24h_assoc : t -> (string * float) list
(** Per-keeper 24h USD costs from [keeper_costs] for Company rollup. *)

val keeper_spend_rows : t -> keeper_spend_row list
(** Ranked per-keeper cost & efficiency table rows (combining [efficiency] MTD
    and [keeper_costs] 24h so the table is populated on both live and isolated
    servers). *)

val grouped_keeper_spend_rows : t -> company_spend_group list
(** Canonical SSOT company-grouped Efficiency & Spend rows: companies sorted by
    total USD desc then company name asc; members inside each company sorted by
    USD desc then calls desc then keeper name asc. *)

val keeper_spend_display_rows : t -> keeper_spend_row list
(** Flattened visual display order of {!grouped_keeper_spend_rows}, shared by
    both [Screen_runtime.render_efficiency_spend] and [move_selection]. *)

val selected_keeper_spend_row : t -> keeper_spend_row option
(** Currently selected keeper row in {!keeper_spend_display_rows}. *)

val company_spend_rollups : t -> company_spend_row list
(** Company/group spend & call rollup derived from {!keeper_spend_rows}. *)

val set_fusion_prompt : string -> t -> t
val set_fusion_keeper : string option -> t -> t
val set_fusion_preset : string option -> t -> t
val set_fusion_topology : Wire_runtime.fusion_topology option -> t -> t
val toggle_fusion_web_tools : t -> t
val set_fusion_submitting : bool -> t -> t
val clear_fusion_draft : t -> t
val to_fusion_launch_request :
  t -> (string * Wire_runtime.fusion_launch_request, string) result

val selected_lane : t -> Wire_runtime.failover_lane option
val runtime_options : t -> Wire_runtime.runtime_option list

val move_selection :
  ?pane_index:int -> ?viewport_rows:int -> delta:int -> t -> t
val set_filter : string -> t -> t
val mark_stale_all : t -> t
