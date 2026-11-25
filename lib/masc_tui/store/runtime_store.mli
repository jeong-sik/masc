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

type tools_subview =
  | Tools_usage_calls
  | Tools_catalog_tree
  | Tools_keeper_skills
  | Tools_quality_gate
  | Tools_prompts_presets

type prompts_presets_section =
  | Sec_prompts
  | Sec_presets
  | Sec_params
  | Sec_async_requests

type tools_window =
  | Tools_win_24h
  | Tools_win_7d
  | Tools_win_14d

type tool_family_group = {
  family : string;
  tools : Wire_runtime.tool_catalog_entry list;
}

type tool_domain_group = {
  domain : string;
  families : tool_family_group list;
  total_calls : int;
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
  runtime_standings : Wire_runtime.runtime_standing String_map.t;
  runtime_standings_error : string option;
  runtime_config_raw : Wire_runtime.runtime_config_raw_meta Observed.t;
  setup_inventory : Wire_runtime.setup_inventory Observed.t;
  setup_login_receipt : Wire_runtime.setup_login_receipt option;
  setup_login_auth_url : string option;
  setup_login_device_code : string option;
  setup_login_input_ready : bool;
  setup_login_output_lines : string list;
  runtime_probe : Wire_runtime.runtime_probe_snapshot Observed.t;
  exact_lane_runs : Wire_runtime.exact_lane_run list Observed.t;
  lanes_inventory : Wire_runtime.lane_inventory_snapshot Observed.t;
  lanes_inventory_absent : bool;
  lanes_inventory_auth_denied : bool;
  standalone_lanes : Wire_runtime.standalone_lanes_snapshot Observed.t;
  standalone_lanes_absent : bool;
  standalone_lanes_auth_denied : bool;
  exact_run_detail : (string * Wire_runtime.exact_lane_run_detail) Observed.t;
  verification_runs : Wire_runtime.verifier_runs_snapshot Observed.t;
  goal_verification_runs : Wire_runtime.verifier_runs_snapshot Observed.t;
  board_attention_quarantines :
    (string * Wire_runtime.board_attention_quarantines_snapshot) Observed.t;
  runtime_raw_preview : Wire_runtime.runtime_raw_preview_result Observed.t;
  addon_declaration_doc :
    (string * Wire_runtime.addon_declaration_document) Observed.t;
  pending_addon_decl_path : string option;
  addon_last_action_receipt : Wire_runtime.addon_action_receipt Observed.t;
  addon_slice : Wire_runtime.addon_slice_snapshot Observed.t;
  addon_req_seq : int;
  browser_scene : (int * Wire_runtime.browser_scene_snapshot) Observed.t;
  browser_screenshot : (int * Wire_runtime.browser_screenshot_meta) Observed.t;
  browser_last_receipt : Wire_runtime.browser_op_receipt Observed.t;
  fusion_runs : Wire_runtime.fusion_run list Observed.t;
  fusion_replay : Wire_runtime.fusion_replay_status option;
  fusion_historical_evidence : Wire_runtime.fusion_historical_evidence list;
  fusion_detail : (string * Wire_runtime.fusion_run_detail) Observed.t;
  fusion_board_evidence : (string * Wire_runtime.fusion_evidence_post) Observed.t;
  fusion_config : Wire_runtime.fusion_config_options Observed.t;
  fusion_config_auth_denied : bool;
  fusion_launch_draft : fusion_draft;
  tool_series : Wire_runtime.tool_series Observed.t;
  tool_series_summary : Wire_runtime.tool_series_summary Observed.t;
  tool_detail_series : (string * Wire_runtime.tool_series_summary) Observed.t;
  tools_dashboard : Wire_runtime.tools_dashboard_snapshot Observed.t;
  tools_catalog : Wire_runtime.tool_summary list Observed.t;
  tool_quality : Wire_runtime.tool_quality_snapshot Observed.t;
  tool_quality_absent : bool;
  gate_tool_events : Wire_work.gate_tool_events_snapshot Observed.t;
  gate_tool_events_absent : bool;
  keeper_waiting_inventory :
    (string * Wire_runtime.keeper_waiting_inventory) Observed.t;
  keeper_waiting_inventory_absent : bool;
  mcp_tools_list : Wire_runtime.mcp_tool_schema_entry list Observed.t;
  mcp_call_result : Wire_runtime.mcp_tool_call_result Observed.t;
  mcp_call_form : (int * Nav.inline_action_kind) option;
  mcp_next_rpc_id : int;
  skills : Wire_runtime.skills_snapshot Observed.t;
  skill_editor_sources : string list Observed.t;
  skill_editor_sources_absent : bool;
  skill_editor_sources_auth_denied : bool;
  skill_editor_tools : Wire_runtime.skill_authoring_tool list Observed.t;
  skill_editor_tools_absent : bool;
  skill_editor_tools_auth_denied : bool;
  skill_editor_loaded : (string * Wire_runtime.skill_editor_loaded) Observed.t;
  skill_editor_preview : Wire_runtime.skill_editor_preview Observed.t;
  skill_selected_index : int;
  skill_scroll_offset : int;
  async_requests : Wire_runtime.async_requests_snapshot Observed.t;
  async_requests_absent : bool;
  async_requests_auth_denied : bool;
  prompts_catalog : Wire_runtime.prompts_catalog Observed.t;
  prompts_absent : bool;
  presets_listing : Wire_runtime.presets_listing Observed.t;
  presets_absent : bool;
  presets_auth_denied : bool;
  pending_preset_select : string option;
  preset_detail : (string * Wire_runtime.preset_detail) Observed.t;
  runtime_params : Wire_runtime.runtime_params_snapshot Observed.t;
  runtime_params_absent : bool;
  pp_section : prompts_presets_section;
  pp_selected_index : int;
  pp_scroll_offset : int;
  tools_subview : tools_subview;
  tools_window : tools_window;
  tools_surface_keeper_idx : int;
  tools_catalog_selected_index : int;
  tools_catalog_scroll_offset : int;
  connectors : Wire_runtime.connector_row list Observed.t;
  connector_names : Wire_runtime.connector_name_mapping list String_map.t;
  browser_lane : Wire_runtime.browser_lane_status Observed.t;
  browser_tabs : Wire_runtime.browser_tabs_response Observed.t String_map.t;
  lane_addons : Wire_runtime.lane_addons_snapshot Observed.t;
  lane_addon_asks : Wire_runtime.lane_addon_ask_row list Observed.t;
  addon_catalog_mode : bool;
  addon_package_catalog : Wire_runtime.addon_package_catalog Observed.t;
  addon_catalog_selected_index : int;
  addon_catalog_scroll_offset : int;
  addon_package_preview :
    (string * Wire_runtime.addon_package_preview) Observed.t;
  mcp_clients : Wire_runtime.mcp_client_row list Observed.t;
  keeper_companies : string String_map.t;
  show_outside_lane_probes : bool;
  show_unreported_accounts : bool;
  selected_index : int;
  scroll_offset : int;
  quota_scroll_offset : int;
  fusion_selected_index : int;
  fusion_scroll_offset : int;
  connector_selected_index : int;
  connector_scroll_offset : int;
  mcp_client_selected_index : int;
  mcp_client_scroll_offset : int;
  addon_selected_index : int;
  addon_scroll_offset : int;
  browser_client_selected_index : int;
  browser_client_scroll_offset : int;
  browser_tab_selected_index : int;
  browser_tab_scroll_offset : int;
  browser_right_focus : [ `Clients | `Tabs ];
  detail_scroll_offset : int;
  filter_query : string;
}

val equal_tools_subview : tools_subview -> tools_subview -> bool
val equal_tools_window : tools_window -> tools_window -> bool
val tools_window_params : tools_window -> [ `Hour | `Day ] * int
val tools_window_label : tools_window -> string
val cycle_tools_subview : t -> t
val set_tools_subview : tools_subview -> t -> t
val cycle_tools_window : t -> t
val step_tools_surface_keeper :
  keeper_names:string list -> delta:int -> t -> t * string option
val selected_tools_surface_keeper :
  keeper_names:string list -> t -> string option

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
val apply_runtime_config_raw :
  observed_at:Clock.Mono.t -> Wire_runtime.runtime_config_raw_meta -> t -> t
val apply_setup_inventory :
  observed_at:Clock.Mono.t -> Wire_runtime.setup_inventory -> t -> t
val apply_setup_login_receipt : Wire_runtime.setup_login_receipt -> t -> t
val apply_setup_login_output :
  text:string ->
  auth_url:string option ->
  device_code:string option ->
  t ->
  t
val mark_setup_login_input_ready : bool -> t -> t
val active_setup_login_id : t -> string option
(** [Some login_id] when the latest setup login receipt is non-terminal. *)
val apply_runtime_probe :
  observed_at:Clock.Mono.t -> Wire_runtime.runtime_probe_snapshot -> t -> t
val apply_exact_lane_runs :
  observed_at:Clock.Mono.t -> Wire_runtime.exact_lane_run list -> t -> t
val apply_fusion_runs :
  observed_at:Clock.Mono.t -> Wire_runtime.fusion_run list -> t -> t
val apply_tool_series :
  observed_at:Clock.Mono.t -> Wire_runtime.tool_series -> t -> t
val apply_tool_series_summary :
  observed_at:Clock.Mono.t -> Wire_runtime.tool_series_summary -> t -> t
val apply_tool_detail_series :
  observed_at:Clock.Mono.t ->
  tool:string ->
  Wire_runtime.tool_series_summary ->
  t ->
  t
val apply_tools_dashboard :
  observed_at:Clock.Mono.t -> Wire_runtime.tools_dashboard_snapshot -> t -> t
val apply_tools_catalog :
  observed_at:Clock.Mono.t -> Wire_runtime.tool_summary list -> t -> t
val apply_tools_warming : observed_at:Clock.Mono.t -> t -> t
(** The server answered its warming payload. A loaded catalog stays, marked
    stale; otherwise the panel waits ([Loading]). Either way the next view of
    the panel asks again. *)

val apply_skills :
  observed_at:Clock.Mono.t -> Wire_runtime.skills_snapshot -> t -> t
val apply_connectors :
  observed_at:Clock.Mono.t -> Wire_runtime.connector_row list -> t -> t
val apply_browser_lane :
  observed_at:Clock.Mono.t -> Wire_runtime.browser_lane_status -> t -> t
val browser_tabs_for :
  client_id:string -> t -> Wire_runtime.browser_tabs_response Observed.t
val apply_browser_tabs :
  observed_at:Clock.Mono.t ->
  client_id:string ->
  Wire_runtime.browser_tabs_response ->
  t ->
  t
val mark_browser_tabs_loading :
  since:Clock.Mono.t -> client_id:string -> t -> t
val mark_browser_tabs_failed :
  at:Clock.Mono.t ->
  client_id:string ->
  reason:string ->
  retryable:bool ->
  t ->
  t
val apply_lane_addons :
  observed_at:Clock.Mono.t -> Wire_runtime.lane_addons_snapshot -> t -> t
val apply_lane_addon_asks :
  observed_at:Clock.Mono.t -> Wire_runtime.lane_addon_ask_row list -> t -> t
val lane_addon_asks_list : t -> Wire_runtime.lane_addon_ask_row list
val open_lane_addon_asks : t -> Wire_runtime.lane_addon_ask_row list
val apply_mcp_clients :
  observed_at:Clock.Mono.t -> Wire_runtime.mcp_client_row list -> t -> t
val toggle_browser_right_focus : t -> t

val active_and_outside_probes :
  t -> Wire_runtime.provider_probe_row list * Wire_runtime.provider_probe_row list
(** Partition async runtime-probe rows strictly by active failover lanes so
    outside-lane failures never pollute active-lane health headers. *)

val toggle_outside_lane_probes : t -> t
val toggle_unreported_accounts : t -> t
val set_show_unreported_accounts : bool -> t -> t

val filtered_accounts : t -> Wire_runtime.account_usage list
val subscription_window_count : t -> int
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

val keeper_cost_usd : keeper:string -> t -> float Observed.t
(** The keeper's [total_cost_usd] over the [keeper_costs] window; [Absent]
    when the response has no row for the keeper or no turn reported a cost. *)

val keeper_tokens : keeper:string -> t -> int Observed.t
(** The keeper's [total_tokens] over the [keeper_costs] window, under the
    same rule as [keeper_cost_usd]. *)

val keeper_costs_window_label : t -> string option
(** ["24h"] for the loaded [keeper_costs] [window_minutes]; [None] before the
    response arrives. *)

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

val filtered_lanes : t -> Wire_runtime.failover_lane list
val filtered_tools : t -> Wire_runtime.tool_summary list
val filtered_tool_catalog_entries : t -> Wire_runtime.tool_catalog_entry list
val grouped_tools_catalog : t -> tool_domain_group list
val tools_catalog_display_entries : t -> Wire_runtime.tool_catalog_entry list
val selected_tool_catalog_entry : t -> Wire_runtime.tool_catalog_entry option
val filtered_fusion_runs : t -> Wire_runtime.fusion_run list
val selected_fusion_run : t -> Wire_runtime.fusion_run option
val filtered_connectors : t -> Wire_runtime.connector_row list
val filtered_mcp_clients : t -> Wire_runtime.mcp_client_row list
val selected_mcp_client : t -> Wire_runtime.mcp_client_row option
val filtered_addon_instances : t -> Wire_runtime.addon_instance list
val declaration_for_addon :
  Wire_runtime.addon_instance -> t -> Wire_runtime.addon_declaration option
val filtered_browser_clients : t -> Wire_runtime.browser_client_row list
val filtered_browser_tabs : t -> Wire_runtime.browser_tab_row list
val selected_lane : t -> Wire_runtime.failover_lane option
val selected_connector : t -> Wire_runtime.connector_row option
val selected_addon_instance : t -> Wire_runtime.addon_instance option
val selected_live_dos_screen : t -> bool
val selected_browser_client : t -> Wire_runtime.browser_client_row option
val selected_browser_tab : t -> Wire_runtime.browser_tab_row option
val runtime_options : t -> Wire_runtime.runtime_option list

val move_selection :
  ?pane_index:int ->
  ?viewport_rows:int ->
  ?max_detail_scroll:int ->
  delta:int ->
  t ->
  t
val reset_detail_scroll : t -> t
val set_filter : string -> t -> t
val mark_stale_all : t -> t

val apply_fusion_runs_snapshot :
  observed_at:Clock.Mono.t -> Wire_runtime.fusion_runs_snapshot -> t -> t
val apply_fusion_detail :
  observed_at:Clock.Mono.t ->
  run_id:string ->
  Wire_runtime.fusion_run_detail ->
  t ->
  t
val fusion_detail_for : run_id:string -> t -> Wire_runtime.fusion_run_detail option
val apply_fusion_board_evidence :
  observed_at:Clock.Mono.t ->
  post_id:string ->
  Wire_runtime.fusion_evidence_post ->
  t ->
  t
val fusion_board_evidence_for :
  post_id:string -> t -> Wire_runtime.fusion_evidence_post option
val is_retained_fusion_run : run_id:string -> t -> bool
val historical_evidence_for_run :
  run_id:string -> t -> Wire_runtime.fusion_historical_evidence option
val apply_fusion_config :
  observed_at:Clock.Mono.t -> Wire_runtime.fusion_config_options -> t -> t
val mark_fusion_config_denied : at:Clock.Mono.t -> reason:string -> t -> t
val toggle_addon_catalog_mode : t -> t
val apply_addon_package_catalog :
  observed_at:Clock.Mono.t -> Wire_runtime.addon_package_catalog -> t -> t
val apply_addon_package_preview :
  observed_at:Clock.Mono.t ->
  manifest_path:string ->
  Wire_runtime.addon_package_preview ->
  t ->
  t
val filtered_addon_catalog_entries : t -> Wire_runtime.addon_catalog_entry list
val selected_addon_catalog_entry : t -> Wire_runtime.addon_catalog_entry option
val addon_preview_for :
  manifest_path:string -> t -> Wire_runtime.addon_package_preview option
val apply_connector_names :
  connector_id:string -> Wire_runtime.connector_name_mapping list -> t -> t
val connector_channel_names :
  connector_id:string -> t -> Wire_runtime.connector_name_mapping list

val apply_tool_quality :
  observed_at:Clock.Mono.t -> Wire_runtime.tool_quality_snapshot -> t -> t
val apply_gate_tool_events :
  observed_at:Clock.Mono.t -> Wire_work.gate_tool_events_snapshot -> t -> t
val apply_keeper_waiting_inventory :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_runtime.keeper_waiting_inventory ->
  t ->
  t
val keeper_waiting_inventory_for :
  keeper:string -> t -> Wire_runtime.keeper_waiting_inventory option

val apply_runtime_standings :
  (string * Wire_runtime.runtime_standing) list -> t -> t

val mark_runtime_standings_failed : string -> t -> t
(** Record a standings decode failure without wiping previously observed
    degraded standings. *)

val standing_for :
  runtime_id:string -> t -> Wire_runtime.runtime_standing option

val degraded_standings :
  now_unix:float -> t -> (string * Wire_runtime.runtime_standing) list
val apply_mcp_tools_list :
  observed_at:Clock.Mono.t -> Wire_runtime.mcp_tool_schema_entry list -> t -> t
val mcp_tool_schema_for :
  name:string -> t -> Wire_runtime.mcp_tool_schema_entry option
val apply_mcp_call_result :
  observed_at:Clock.Mono.t -> Wire_runtime.mcp_tool_call_result -> t -> t
val next_mcp_rpc_id : t -> t * int

val equal_prompts_presets_section :
  prompts_presets_section -> prompts_presets_section -> bool
val set_prompts_presets_section : prompts_presets_section -> t -> t
val cycle_prompts_presets_section : t -> t
val apply_skill_editor_sources :
  observed_at:Clock.Mono.t -> string list -> t -> t
val apply_skill_editor_tools :
  observed_at:Clock.Mono.t -> Wire_runtime.skill_authoring_tool list -> t -> t
val apply_skill_editor_loaded :
  observed_at:Clock.Mono.t ->
  reference:string ->
  Wire_runtime.skill_editor_loaded ->
  t ->
  t
val skill_editor_loaded_for :
  reference:string -> t -> Wire_runtime.skill_editor_loaded option
type skill_mutation_target =
  | Loaded_skill of Wire_runtime.skill_editor_loaded
  | Catalog_skill of Yojson.Safe.t

val skill_mutation_target : reference:string -> t -> skill_mutation_target option
(** A saved or deleted target uses an exact, nonblank skill identity. A read
    alias or ambiguous catalogue name cannot authorize a write. *)

val apply_skill_editor_preview :
  observed_at:Clock.Mono.t -> Wire_runtime.skill_editor_preview -> t -> t
val filtered_skill_surfaces : t -> Wire_runtime.skill_surface_entry list
val selected_skill_surface : t -> Wire_runtime.skill_surface_entry option
val find_skill_surface : reference:string -> t -> Wire_runtime.skill_surface_entry option
val apply_async_requests :
  observed_at:Clock.Mono.t -> Wire_runtime.async_requests_snapshot -> t -> t
val apply_prompts_catalog :
  observed_at:Clock.Mono.t -> Wire_runtime.prompts_catalog -> t -> t
val apply_presets_listing :
  observed_at:Clock.Mono.t -> Wire_runtime.presets_listing -> t -> t
val apply_preset_detail :
  observed_at:Clock.Mono.t ->
  name:string ->
  Wire_runtime.preset_detail ->
  t ->
  t
val preset_detail_for : name:string -> t -> Wire_runtime.preset_detail option
val apply_runtime_params :
  observed_at:Clock.Mono.t -> Wire_runtime.runtime_params_snapshot -> t -> t
val filtered_prompts : t -> Wire_runtime.prompt_item list
val selected_prompt_item : t -> Wire_runtime.prompt_item option
val filtered_presets : t -> Wire_runtime.preset_manifest list
val selected_preset_manifest : t -> Wire_runtime.preset_manifest option
val select_preset_by_name : string -> t -> t
val filtered_runtime_params : t -> Wire_runtime.runtime_param_item list
val selected_runtime_param : t -> Wire_runtime.runtime_param_item option
val filtered_async_requests : t -> Wire_runtime.async_request_row list
val selected_async_request : t -> Wire_runtime.async_request_row option

val apply_lanes_inventory :
  observed_at:Clock.Mono.t -> Wire_runtime.lane_inventory_snapshot -> t -> t
val apply_standalone_lanes :
  observed_at:Clock.Mono.t -> Wire_runtime.standalone_lanes_snapshot -> t -> t
val apply_exact_run_detail :
  observed_at:Clock.Mono.t ->
  run_id:string ->
  Wire_runtime.exact_lane_run_detail ->
  t ->
  t
val exact_run_detail_for :
  run_id:string -> t -> Wire_runtime.exact_lane_run_detail option
val apply_verification_runs :
  observed_at:Clock.Mono.t -> Wire_runtime.verifier_runs_snapshot -> t -> t
val apply_goal_verification_runs :
  observed_at:Clock.Mono.t -> Wire_runtime.verifier_runs_snapshot -> t -> t
val apply_board_attention_quarantines :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_runtime.board_attention_quarantines_snapshot ->
  t ->
  t
val apply_runtime_raw_preview :
  observed_at:Clock.Mono.t -> Wire_runtime.runtime_raw_preview_result -> t -> t
val apply_addon_declaration_doc :
  observed_at:Clock.Mono.t ->
  source_path:string ->
  Wire_runtime.addon_declaration_document ->
  t ->
  t
val apply_addon_action_receipt :
  observed_at:Clock.Mono.t -> Wire_runtime.addon_action_receipt -> t -> t
val apply_addon_slice :
  observed_at:Clock.Mono.t -> Wire_runtime.addon_slice_snapshot -> t -> t
val next_addon_request_id : t -> t * string
val apply_browser_scene :
  observed_at:Clock.Mono.t ->
  tab_id:int ->
  Wire_runtime.browser_scene_snapshot ->
  t ->
  t
val apply_browser_screenshot :
  observed_at:Clock.Mono.t ->
  tab_id:int ->
  Wire_runtime.browser_screenshot_meta ->
  t ->
  t
val apply_browser_op_receipt :
  observed_at:Clock.Mono.t -> Wire_runtime.browser_op_receipt -> t -> t
