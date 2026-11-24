(** Runtime & Telemetry wire codecs: Provider/Model-Free Quotas & Subscription
    Windows vs API Credit Balances (strict [$0 Sub] / [$0 Exhausted] /
    [? Unreported] classification), Efficiency & Prompt Cache % + Dual Token
    Velocity, Failover Lanes decoupled from Runtime Probe, Exact Lanes, Fusion
    fan-out, Tool Metrics, Connectors, Browser Lane, and MCP Clients. *)

open Masc_tui_core

val runtime_resolved_path : string
val runtime_config_raw_path : string
val runtime_assignment_path : string
val runtime_routing_path : string
val setup_inventory_path : string
val setup_credential_path : string
val setup_accounts_login_path : string
val setup_accounts_login_status_path : login_id:string -> string
val setup_accounts_login_input_path : login_id:string -> string
val runtime_probe_path : ?force:bool -> unit -> string
val provider_usage_history_path : days:int -> string
val keeper_costs_path : window_minutes:int -> string
val keeper_efficiency_path : ?month:string -> unit -> string
val models_chart_window_minutes : int
val models_chart_bucket_minutes : int
(** The model spend chart reads 24 hours in 60-minute buckets. *)

val models_metrics_path : window_minutes:int -> bucket_minutes:int -> string

val models_metrics_stream_path : string
(** The live stream asks for the chart's window and bucket. Without them the
    server streams its 30-minute unbucketed aggregate, which cannot replace
    the chart's snapshot. *)
val runtime_metrics_path : string
val tool_series_path : bucket:[ `Hour | `Day ] -> since_hours:int -> string
val tool_series_filtered_path :
  bucket:[ `Hour | `Day ] -> since_hours:int -> ?tool:string -> unit -> string
val dashboard_tools_path : ?keeper:string -> unit -> string
val tool_quality_path : ?n:int -> ?window_hours:int -> unit -> string
val keeper_waiting_inventory_path : keeper:string -> string
val mcp_rpc_path : string
val mcp_protocol_version : string
val skills_path : string
val connector_unbind_path : connector:string -> string
val connector_names_path : connector:string -> ?scope:string -> ?limit:int -> unit -> string
val fusion_runs_path : string
val fusion_run_detail_path : run_id:string -> string
val fusion_config_path : string
val fusion_board_post_path : post_id:string -> string
val fusion_launch_path : keeper:string -> string
val exact_lane_runs_path : ?lane:string -> ?limit:int -> unit -> string
val connectors_path : string

val connector_bind_path : connector:string -> string
(** [POST /api/v1/gate/connector/bind?name=<connector>]. *)
val browser_lane_path : string
val browser_lane_read_path : string
val lane_addons_path : string
val lane_addon_attach_path : string
val lane_addon_detach_path : string
val lane_addon_actions_path : string
val lane_addon_asks_path : ?include_resolved:bool -> unit -> string
val lane_addon_ask_answer_path : string
val lane_addon_package_catalog_path : ?directory:string -> unit -> string
val lane_addon_package_preview_path : manifest_path:string -> string
val mcp_clients_path : string

(** {1 Provider-Free Quotas, Subscription Windows & Credit Balances} *)

type usage_window_kind =
  | Window_five_hour
  | Window_seven_day
  | Window_duration_minutes of int
  | Window_provider_label of string

type usage_window_role =
  | Role_gates_model_calls
  | Role_counts_other_use
  | Role_unclassified_limit

type usage_utilization =
  | Util_fraction of float
  | Util_percent of int
  | Util_usd of { used : float; limit : float option }
  | Util_credit_balance of {
      currency : string;
      total : float option;
      remaining : float;
    }
  | Util_credit_unlimited
  | Util_credit_retracted

type usage_window = {
  limit_id : string option;
  kind : usage_window_kind;
  role : usage_window_role;
  utilization : usage_utilization;
  resets_at_unix : float option;
  observed_at_unix : float;
}

type account_usage_state =
  | Account_not_reported_since_start
  | Account_reported_no_windows of { observed_at_unix : float; source : string }
  | Account_reported of usage_window list

type usage_provider_ref = {
  id : string;
  display_name : string;
}

type account_usage = {
  scope : string;
  scope_id : string;
  providers : usage_provider_ref list;
  state : account_usage_state;
  cost_state : Format_val.cost_state;
}

type provider_usage_windows = {
  since_unix : float;
  accounts : account_usage list;
}

val classify_account_cost_state : account_usage_state -> Format_val.cost_state
(** Classify account billing/quota state strictly into {!Format_val.cost_state}:
    - Subscription window ([Util_fraction]/[Util_percent]/[Util_credit_unlimited])
      maps to [Subscription_zero] (["$0 Sub"]).
    - API credit balance with [remaining <= 0.0] maps to [Exhausted_zero]
      (["$0 Exhausted"]); positive remaining maps to [Amount remaining].
    - [Util_usd] maps to [Amount used] (or [Exhausted_zero] if [limit = Some l]
      and [used >= l]).
    - [Account_not_reported_since_start] / [Account_reported_no_windows] /
      [Util_credit_retracted] map to [Unreported] (["? Unreported"]). *)

val decode_provider_usage_windows :
  Yojson.Safe.t -> (provider_usage_windows, string) result

type provider_usage_history_point = {
  scope_id : string;
  source : string;
  kind : string;
  limit_id : string option;
  observed_at_unix : float;
  resets_at_unix : float option;
  utilization : usage_utilization;
}

type provider_usage_no_window = {
  scope_id : string;
  observed_at_unix : float;
}

type provider_usage_history =
  | Usage_history_unavailable of string
  | Usage_history_ready of {
      days : int;
      generated_at_unix : float;
      unreadable_reports : int;
      reported_no_windows : provider_usage_no_window list;
      points : provider_usage_history_point list;
    }

val decode_provider_usage_history :
  Yojson.Safe.t -> (provider_usage_history, string) result
(** Decode [GET /api/v1/dashboard/provider-usage-history?days=N] with its
    actual history projection schema (distinct from [/api/v1/runtime/resolved]
    live [provider_usage_windows]). *)

type keeper_cost_row = {
  keeper_name : string;
  sample_count : int;
  total_tokens : int Observed.t;
  total_cost_usd : float Observed.t;
  tokens_reported_samples : int;
  tokens_missing_samples : int;
  cost_reported_samples : int;
  cost_missing_samples : int;
}

type keeper_costs_window = {
  generated_at_unix : float;
  window_minutes : int;
  rows : keeper_cost_row list;
}

val decode_keeper_costs_window :
  observed_at:Clock.Mono.t -> Yojson.Safe.t -> (keeper_costs_window, string) result

(** {1 Efficiency, Prompt Cache % & Dual Token Velocity} *)

type keeper_efficiency_row = {
  keeper : string;
  turns : int;
  input_tokens : int;
  cache_read_tokens : int Observed.t;
  cache_creation_tokens : int Observed.t;
  output_tokens : int;
  cache_hit_pct : float Observed.t;
  cost_usd : float;
  calls : int;
  failed : int;
  deferred : int;
  tool_ms : float;
}

type fleet_efficiency = {
  turns_total : int;
  calls_per_turn : float;
  tool_s_per_turn : float;
  output_tokens_per_turn : float;
  input_tokens_per_turn : float;
  cost_usd_per_turn : float;
  fleet_cache_hit_pct : float Observed.t;
}

type token_velocity_sample = {
  at_unix : float;
  input_tok_per_min : float Observed.t;
  cache_read_tok_per_min : float Observed.t;
  output_tok_per_min : float Observed.t;
}

type efficiency_window_kind =
  | Efficiency_month_mtd
  | Efficiency_month_complete

type efficiency_month = {
  month : string;
  window_kind : efficiency_window_kind option;
  generated_at_unix : float;
  days_covered : int;
  keepers : keeper_efficiency_row list;
  fleet : fleet_efficiency;
  velocity : token_velocity_sample list;
}

val compute_cache_hit_pct :
  input_tokens:int -> cache_read_tokens:int -> float option
(** Compute prompt cache hit percentage as [cache_read_tokens / input_tokens * 100],
    clamped to [[0.0, 100.0]]. Cache reads are a subset of inclusive
    [input_tokens] per [Model_inference_metrics_entry]. *)

val decode_efficiency_month :
  observed_at:Clock.Mono.t -> Yojson.Safe.t -> (efficiency_month, string) result

(** {1 24h Model & Runtime Inference Metrics ([/api/v1/models/metrics], [/api/v1/runtime/metrics])} *)

type paired_cached_input = {
  input_tokens : int;
  cache_read_tokens : int;
  sample_count : int;
}

type model_metrics_bucket = {
  ts_start : float;
  entry_count : int;
  success_count : int;
  error_count : int;
  p50_latency_ms : float option;
  p95_latency_ms : float option;
  error_rate : float;
  total_cost_usd : float option;
  cache_hit_ratio : float option;
  input_tokens : int option;
  output_tokens : int option;
  cache_read_tokens : int option;
}

type model_metrics_row = {
  model_id : string;
  entry_count : int;
  success_count : int;
  error_count : int;
  avg_tok_per_sec : float option;
  p50_latency_ms : float option;
  p95_latency_ms : float option;
  total_input_tokens : int option;
  total_output_tokens : int option;
  total_cache_read_tokens : int option;
  total_cache_creation_tokens : int option;
  cached_input : paired_cached_input option;
  total_cost_usd : float option;
  total_tool_calls : int;
  buckets : model_metrics_bucket list;
}

type aggregated_metrics_bucket = {
  ts_start : float;
  entry_count : int;
  success_count : int;
  error_count : int;
  total_cost_usd : float;
  p95_latency_ms : float option;
  cache_hit_pct : float option;
  input_tokens : int option;
  output_tokens : int option;
  cache_read_tokens : int option;
}

type models_metrics_snapshot = {
  window_minutes : int;
  bucket_minutes : int;
  total_entries : int;
  total_error_entries : int;
  models : model_metrics_row list;
  hourly_buckets : aggregated_metrics_bucket list;
  fleet_cache_hit_pct : float Observed.t;
  fleet_cost_usd : float Observed.t;
  fleet_input_tokens : int;
  fleet_output_tokens : int;
  fleet_cache_read_tokens : int;
  fleet_cache_creation_tokens : int;
  fleet_tool_calls : int;
  fleet_p95_latency_ms : float option;
}

type runtime_metrics_state =
  | Runtime_metrics_ready
  | Runtime_metrics_unavailable of string

type runtime_metrics_snapshot = {
  state : runtime_metrics_state;
  observed_at_unix : float option;
  window_minutes : int;
  attributed_entries : int;
  unattributed_entries : int;
  runtimes : model_metrics_row list;
  hourly_buckets : aggregated_metrics_bucket list;
  fleet_cache_hit_pct : float Observed.t;
  fleet_cost_usd : float Observed.t;
  fleet_input_tokens : int;
  fleet_output_tokens : int;
  fleet_cache_read_tokens : int;
  fleet_cache_creation_tokens : int;
  fleet_tool_calls : int;
}

val decode_models_metrics :
  observed_at:Clock.Mono.t ->
  Yojson.Safe.t ->
  (models_metrics_snapshot, string) result

val decode_runtime_metrics :
  observed_at:Clock.Mono.t ->
  Yojson.Safe.t ->
  (runtime_metrics_snapshot, string) result

(** {1 Failover Lanes & Decoupled Runtime Probe} *)

type failover_lane = {
  id : string;
  declared : bool;
  runtime_ids : string list;
}

type runtime_option = {
  id : string;
  provider_id : string;
  provider : string;
  model : string option;
  declared_reasoning_effort : string option;
  transport : string option;
  is_default : bool;
}

type runtime_resolved_snapshot = {
  generated_at_iso : string;
  config_path : string option;
  default_route : string option;
  lanes : failover_lane list;
  runtimes : runtime_option list;
  usage_windows : provider_usage_windows option;
}

val decode_runtime_resolved :
  Yojson.Safe.t -> (runtime_resolved_snapshot, string) result

(** {1 Human Provider & Runtime Slot Aliases} *)

val human_provider_id_label :
  ?runtimes:runtime_option list ->
  ?display_name:string ->
  string ->
  string
(** Convert a raw provider ID (e.g. ["claude_code_a1b2c3d4"],
    ["antigravity_e5f60718"], ["kimi_coding"]) into a clean human display name
    without raw 8-char hex hashes (falling back to short ["#1c05"] when
    unbound). *)

val human_provider_label :
  ?lang:Say.lang ->
  ?runtimes:runtime_option list ->
  ?all_accounts:account_usage list ->
  account_usage ->
  string
(** Clean human display label for a provider usage account: resolves raw hash
    IDs via binding tags ([alice], [bob]) or short hash ([#1c05]), collapses
    unique CLI accounts ([Antigravity CLI], [Codex CLI (N계정)]),
    and NEVER appends [(#scope_id)] when the label is already unique. *)

val human_runtime_slot_label :
  ?runtimes:runtime_option list -> string -> string
(** Format a failover lane candidate slot ID cleanly as
    ["<Human Provider> · <model>"]. *)

type probe_refresh_state =
  | Probe_fresh
  | Probe_recent
  | Probe_served_stale
  | Probe_warming_up

type probe_status =
  | Probe_ok
  | Probe_idle
  | Probe_degraded
  | Probe_unreachable
  | Probe_warming

type provider_probe_row = {
  runtime_id : string;
  transport : [ `Http | `Cli ];
  status : string;
  reachable : bool option;
  http_status : int option;
  latency_ms : float option;
  error : string option;
  checked_at : string;
}

type runtime_probe_snapshot = {
  generated_at : string;
  cache_ttl_sec : float;
  cache_age_sec : float option;
  cache_hit : bool;
  refresh_state : probe_refresh_state;
  status : probe_status;
  probe_ok : bool;
  default_runtime_id : string option;
  runtimes_count : int;
  probed_count : int;
  reachable_count : int;
  failed_count : int;
  skipped_count : int;
  providers : provider_probe_row list;
  errors : string list;
  observations : string list;
  limitations : string list;
}

val decode_runtime_probe :
  Yojson.Safe.t -> (runtime_probe_snapshot, string) result

val partition_probe_by_active_lanes :
  lanes:failover_lane list ->
  runtime_probe_snapshot ->
  provider_probe_row list * provider_probe_row list
(** Split probe rows into [(active_lane_probes, outside_lane_probes)] so
    outside-lane failures never pollute active-lane health headers. *)

(** {1 Exact Lanes & Fusion Fan-Out} *)

(** [/api/v1/dashboard/exact-lane-runs] merges three registries. Each names
    its statuses with its own [status_label]: [Exact_lane_run_registry],
    [Verification_run_registry] and [Goal_verification_run_registry]. *)
type exact_output_status =
  | Exact_running
  | Exact_succeeded
  | Exact_cancelled
  | Exact_failed of { code : string; detail : string }
  | Exact_completion_persistence_failed
  | Exact_completion_durability_unknown

type task_review_status =
  | Task_review_running
  | Task_review_approved
  | Task_review_rejected
  | Task_review_infrastructure_unavailable
  | Task_review_not_reviewed
  | Task_review_commit_failed
  | Task_review_execution_pending
  | Task_review_execution_repair_required
  | Task_review_raised
  | Task_review_cancelled
  | Task_review_superseded

type goal_review_status =
  | Goal_review_running
  | Goal_review_reviewed
  | Goal_review_committed
  | Goal_review_superseded
  | Goal_review_deferred
  | Goal_review_raised
  | Goal_review_cancelled

type lane_run_status =
  | Exact_output of exact_output_status
  | Task_verification of task_review_status
  | Goal_verification of goal_review_status

type exact_lane_run = {
  run_id : string;
  lane : string;
  subject_id : string option;
      (** The reviewed task or goal id; [None] for an exact-output run. *)
  status : lane_run_status;
  started_at_unix : float;
}

val lane_run_status_label : lane_run_status -> string
(** The server's spelling of the status. *)

val decode_exact_lane_runs : Yojson.Safe.t -> (exact_lane_run list, string) result

type fusion_topology =
  | Simple
  | Refine
  | Conditional
  | Judge_of_judges
  | Staged_judge_of_judges

type fusion_run_status =
  | Fusion_running
  | Fusion_completed
  | Fusion_failed of { code : string; error : string }

type fusion_run = {
  run_id : string;
  keeper : string;
  preset : string;
  topology : fusion_topology;
  started_at_unix : float;
  finished_at_unix : float option;
  status : fusion_run_status;
  stage : string;
  decision : string option;
  summary : string option;
}

type fusion_launch_request = {
  prompt : string;
  preset : string option;
  topology : fusion_topology option;
  web_tools : bool;
}

val fusion_topology_of_string : string -> fusion_topology option
val fusion_topology_to_string : fusion_topology -> string
val decode_fusion_runs : Yojson.Safe.t -> (fusion_run list, string) result
val encode_fusion_launch : fusion_launch_request -> Yojson.Safe.t

(** {1 Tool Metrics, Connectors, Browser Lane & MCP Clients} *)

type tool_series_activity =
  | Series_idle
  | Series_active of {
      calls : int;
      failures : int;
      deferred : int;
      p95_ms : float;
    }

type tool_series_bucket = {
  start_unix : float;
  activity : tool_series_activity;
}

type tool_series = {
  generated_at_unix : float;
  bucket_width : [ `Hour | `Day ];
  utc_offset_min : int;
  buckets : tool_series_bucket list;
}

val decode_tool_series : Yojson.Safe.t -> (tool_series, string) result

type tool_summary = {
  name : string;
  description : string option;
  calls : int Observed.t;
      (** Calls over the server's retained metrics window, [0] for a tool the
          server lists as never called. Unreported when the usage report names
          the tool nowhere (a hidden tool with no call). *)
  failure_rate_pct : float Observed.t;
}

type tools_catalog =
  | Tools_warming
      (** The server's first tools compute has not finished; it answered its
          warming payload. *)
  | Tools_ready of tool_summary list

val decode_tools_catalog :
  observed_at:Clock.Mono.t -> Yojson.Safe.t -> (tools_catalog, string) result

type tool_series_failure_classes = {
  dependency_unavailable : int;
  policy_rejection : int;
  runtime_failure : int;
  workflow_rejection : int;
  operator_cancelled : int;
  unclassified : int;
}

type tool_series_summary = {
  tool_filter : string option;
  total_calls : int;
  total_failures : int;
  total_deferred : int;
  p50_ms : float option;
  p95_ms : float option;
  failure_classes : tool_series_failure_classes;
  series : tool_series;
}

val decode_tool_series_summary :
  Yojson.Safe.t -> (tool_series_summary, string) result

type tool_catalog_entry = {
  name : string;
  description : string option;
  public_names : string list;
  calls_count : int Observed.t;
  failure_count : int;
  failure_rate_pct : float Observed.t;
  p95_ms : float option;
  direct_call_allowed : bool option;
  surfaces : string list;
  domain : string;
  family : string;
  doc_refs : string list;
}

type effective_keeper_tool_entry = {
  name : string;
  origin : string;
}

type effective_keeper_surface =
  | Keeper_surface_unavailable of {
      keeper_name : string;
      reason : string;
      detail : string;
    }
  | Keeper_surface_available of {
      keeper_name : string;
      runtime_id : string;
      tool_delivery : string;
      tool_surface_bytes : int;
      skill_tool_surface_bytes : int;
      skill_discovery_bytes : int;
      skill_body_bytes : int;
      tool_surface_sha256 : string option;
      tools : effective_keeper_tool_entry list;
      skills_left_out : string list;
      lane_addon_conflicts : string list;
    }

type tools_dashboard_snapshot = {
  entries : tool_catalog_entry list;
  total_calls : int;
  distinct_tools_called : int;
  registered_count : int;
  effective_keeper_surface : effective_keeper_surface option;
  volume_gc_summary : string option;
  keeper_cleanup_summary : string option;
}

val decode_tools_dashboard :
  observed_at:Clock.Mono.t ->
  Yojson.Safe.t ->
  (tools_dashboard_snapshot, string) result

val classify_tool_domain_family : string -> string * string

type skill_surface_entry = {
  reference : string;
  kind : string; (** ["instruction" | "composition" | "unavailable"] *)
  summary : string option;
  error : string option;
}

type skills_snapshot = {
  state : string;
  snapshot_revision : string option;
  surfaces : skill_surface_entry list;
  shadows : string list;
  rejections : string list;
}

val decode_skills_snapshot : Yojson.Safe.t -> (skills_snapshot, string) result

type connector_connection =
  | Connector_connected
  | Connector_connected_unavailable
  | Connector_disconnected
  | Connector_offline
  | Connector_stale

type connector_binding = {
  channel_id : string;
  keeper_name : string;
}

type connector_row = {
  connector_id : string;
  display_name : string;
  connection : connector_connection;
  channel : string option;
  error : string option;
  binding_count : int;
  configured_bindings : connector_binding list;
}

val decode_connectors : Yojson.Safe.t -> (connector_row list, string) result

val encode_connector_bind :
  channel_id:string -> keeper_name:string -> Yojson.Safe.t
(** Body for {!connector_bind_path}: the channel to bind and the Keeper that
    answers it. *)

type browser_space_ref = {
  space_id : int;
  space_name : string;
}

type browser_interaction_row = {
  request_id : string;
  actor : string option;
  action : string;
  tab_id : int option;
  phase : string;
}

type browser_settled_activity = {
  work : browser_interaction_row;
  outcome : string;
}

type browser_client_row = {
  client_id : string;
  browser : string;
  version : string;
  engine_version : string;
  transport : string;
  space : browser_space_ref option;
  ownership : string option;
  presence_state : string option;
  presence_reason : string option;
  interactions : browser_interaction_row list;
  last_activities : browser_settled_activity list;
}

type browser_inventory_issue = {
  kind : string;
  instance_id : string option;
  client_id : string option;
  space : string option;
  space_id : int option;
  message : string;
}

type browser_lane_status = {
  ok : bool;
  available : bool;
  inventory_complete : bool;
  client_count : int;
  issue_count : int;
  automatic_browse_ok : bool;
  detail : string option;
  clients : browser_client_row list;
  issues : browser_inventory_issue list;
}

val decode_browser_lane : Yojson.Safe.t -> (browser_lane_status, string) result

type browser_tab_origin =
  | Tab_origin_agent
  | Tab_origin_unknown

type browser_tab_row = {
  id : int;
  title : string;
  url : string;
  active : bool;
  window_id : int option;
  opened_by : browser_tab_origin option;
  label : string option;
  dialog_present : bool;
  dialog_kind : string option;
}

type browser_tabs_response = {
  client_id : string option;
  tabs : browser_tab_row list;
  complete : bool;
  unavailable_count : int;
  error : string option;
}

val encode_browser_tabs_request : client_id:string -> Yojson.Safe.t
val decode_browser_tabs_response :
  Yojson.Safe.t -> (browser_tabs_response, string) result

type addon_runtime_presence =
  | Addon_live
  | Addon_retained

type addon_phase =
  | Addon_attached
  | Addon_observing
  | Addon_detaching
  | Addon_detached
  | Addon_failed
  | Addon_phase_other of string

type addon_declaration = {
  id : string;
  source_path : string;
  enabled : bool;
  source_revision : string;
  desired_revision : string;
  applied_revision : string option;
  instance_id : string option;
  application_kind : string;
  application_messages : string list;
  ui_category : string option;
}

type addon_instance = {
  runtime_presence : addon_runtime_presence;
  instance_id : string;
  addon_id : string;
  title : string;
  revision : string;
  phase : addon_phase;
  execution_kind : string option;
  resolved_image : string option;
  observation_seq : int;
  rows_count : int;
  observation_pending : bool;
  visibility_kind : string option;
  visibility_keeper : string option;
  host_cycles : int option;
  host_waiting_count : int;
  host_issue_kind : string option;
  action_names : string list;
  config_declaration_id : string option;
}

type lane_addons_issue = {
  source_path : string;
  id : string option;
  message : string;
}

type lane_addons_snapshot = {
  configuration_complete : bool;
  declarations : addon_declaration list;
  instances : addon_instance list;
  issues : lane_addons_issue list;
}

val decode_lane_addons : Yojson.Safe.t -> (lane_addons_snapshot, string) result

type lane_addon_ask_row = {
  declaration_id : string;
  title : string;
  ask_id : string;
  asked_at : float;
  context : string option;
  questions : Wire_work.ask_question list;
  resolution : Wire_work.ask_resolution;
}

val decode_lane_addon_asks :
  Yojson.Safe.t -> (lane_addon_ask_row list, string) result

val encode_lane_addon_attach :
  manifest_path:string -> run_id:string -> binding:Yojson.Safe.t -> Yojson.Safe.t

val encode_lane_addon_detach : instance_id:string -> Yojson.Safe.t

val encode_lane_addon_action :
  instance_id:string ->
  expected_incarnation:string ->
  request_id:string ->
  action:Yojson.Safe.t ->
  Yojson.Safe.t

val encode_lane_addon_ask_answer :
  declaration_id:string ->
  ask_id:string ->
  ?session_id:string ->
  answers:(string * Wire_work.ask_response) list ->
  unit ->
  Yojson.Safe.t

type mcp_client_row = {
  name : string;
  agent_type : string;
  keeper_name : string option;
  keeper_id : string option;
  status : string;
  current_task : string option;
  session_bound_at_unix : float option;
  last_seen_unix : float option;
  capabilities : string list;
}

val decode_mcp_clients : Yojson.Safe.t -> (mcp_client_row list, string) result

(** {1 Runtime Assignment, Routing & Setup Inventory / Login} *)

type runtime_config_raw_meta = {
  source_revision : string;
  assignments : (string * string) list;
}

val decode_runtime_config_raw_meta :
  Yojson.Safe.t -> (runtime_config_raw_meta, string) result

val encode_runtime_assignment :
  keeper_name:string ->
  runtime_id:string option ->
  source_revision:string option ->
  previous_runtime_id:string option ->
  unit ->
  Yojson.Safe.t

val encode_runtime_default_route : runtime_id:string -> Yojson.Safe.t

type lane_kind =
  | Lane_failover
  | Lane_exact_output

val equal_lane_kind : lane_kind -> lane_kind -> bool
val lane_kind_of_string : string -> lane_kind option
val lane_kind_to_string : lane_kind -> string
val known_exact_lane_ids : string list
val is_known_exact_lane_id : string -> bool
val is_lowercase_sha256_hex : string -> bool
val parse_candidate_runtime_ids : string -> string list

val encode_runtime_lane_create :
  lane_id:string ->
  kind:lane_kind ->
  runtime_ids:string list ->
  Yojson.Safe.t

val encode_runtime_lane_update :
  lane_id:string ->
  kind:lane_kind ->
  runtime_ids:string list ->
  ?expected_source_revision:string ->
  unit ->
  Yojson.Safe.t

val encode_runtime_lane_delete :
  lane_id:string -> ?expected_source_revision:string -> unit -> Yojson.Safe.t

type setup_integration = {
  id : string;
  display_name : string;
  protocol : string option;
  origin : string;
  setup_support : string;
  enabled : bool;
  credential_kind : string option;
  configured_runtime_ids : string list;
}

type setup_inventory = {
  default_runtime_id : string option;
  integrations : setup_integration list;
}

val decode_setup_inventory : Yojson.Safe.t -> (setup_inventory, string) result

type setup_login_receipt = {
  login_id : string;
  integration_id : string;
  status : string;
  account : string option;
  account_ref : string option;
  authentication : string option;
}

val decode_setup_login_receipt :
  Yojson.Safe.t -> (setup_login_receipt, string) result

type setup_login_key =
  | Login_key_enter
  | Login_key_up
  | Login_key_down
  | Login_key_tab
  | Login_key_eof

type setup_login_input =
  | Setup_login_text of string
  | Setup_login_key of setup_login_key

val encode_setup_login_input : setup_login_input -> Yojson.Safe.t
(** Exact 2-field payload for [POST /api/v1/setup/accounts/login/:id/input]
    matching [Runtime_setup_login_session.input_of_json]. *)

val extract_https_url : string -> string option
(** Extract the first [https://...] URL from CLI login output/screen text,
    stripping ANSI escapes and trailing punctuation. *)

val extract_device_code : string -> string option
(** Extract a hyphenated uppercase device code (e.g. [ABCD-1234]) when present
    in CLI login output/screen text. *)

val encode_setup_credential :
  provider_id:string -> secret:string -> source_revision:string -> Yojson.Safe.t

val encode_setup_account_login_start :
  integration_id:string -> ?account_ref:string -> unit -> Yojson.Safe.t

(** {1 Wave 3: Fusion Detail, Config Presets, Addon Package Catalog & Connector Names} *)

type fusion_replay_status =
  | Replay_not_replayed
  | Replay_absent
  | Replay_complete of {
      lines_read : int;
      malformed_lines : int;
      dropped_running : int;
    }
  | Replay_incomplete of {
      reason : string;
      lines_read : int;
      malformed_lines : int;
    }

type fusion_historical_evidence = {
  run_id : string;
  post_id : string;
  title : string;
  created_at_unix : float;
}

type fusion_runs_snapshot = {
  generated_at : string;
  replay : fusion_replay_status option;
  historical_evidence : fusion_historical_evidence list;
  runs : fusion_run list;
}

type fusion_panel_entry = {
  model : string;
  status : [ `Answered | `Failed ];
  answer : string option;
  input_tokens : int option;
  output_tokens : int option;
  reason_code : string option;
  reason_detail : string option;
}

type fusion_judge_node = {
  role : string;
  identity : string;
  status : string;
  decision : string option;
  resolved_answer : string option;
  synthesis : string option;
  input_tokens : int;
  output_tokens : int;
  failure_code : string option;
  error : string option;
  elapsed_s : float option;
  timed_out : bool option;
}

type fusion_seat_attempt = {
  runtime : string;
  code : string;
  detail : string;
}

type fusion_seat_route = {
  phase : string;
  seat : string;
  judge_role : string option;
  route : string;
  answered_by : string option;
  failed_attempts : fusion_seat_attempt list;
}

type fusion_tool_trace = {
  status : string;
  observed_actors : string list;
  dropped_events : int;
  gaps : string list;
  events_count : int;
  events_preview : string list;
}

type fusion_evidence_post = {
  post_id : string;
  title : string;
  author : string;
  body : string;
  question : string option;
  panel : fusion_panel_entry list;
  judge_status : string option;
  judge_decision : string option;
  judge_synthesis : string option;
  judge_resolved_answer : string option;
  judge_failure : string option;
  judges : fusion_judge_node list;
  seat_routes : fusion_seat_route list;
  tool_trace : fusion_tool_trace option;
}

type fusion_evidence_status =
  | Evidence_recorded of fusion_evidence_post
  | Evidence_pending
  | Evidence_absent

type fusion_run_detail = {
  run : fusion_run;
  evidence : fusion_evidence_status;
}

type fusion_preset_option = {
  name : string;
  panels : string list;
  judge : string option;
  judges : string list;
  min_answered : int option;
}

type fusion_config_options = {
  enabled : bool;
  default_preset : string;
  staged_judge_group_size : int;
  presets : fusion_preset_option list;
}

val decode_fusion_runs_snapshot :
  Yojson.Safe.t -> (fusion_runs_snapshot, string) result
val decode_fusion_run_detail :
  Yojson.Safe.t -> (fusion_run_detail, string) result
val decode_fusion_board_evidence :
  Yojson.Safe.t -> (fusion_evidence_post, string) result
val decode_fusion_config_options :
  Yojson.Safe.t -> (fusion_config_options, string) result

type addon_catalog_entry =
  | Catalog_folder of { path : string }
  | Catalog_issue of { path : string; message : string }
  | Catalog_package of {
      manifest_path : string;
      title : string;
      revision : string;
      description : string option;
      ui_category : string option;
    }

type addon_package_catalog = {
  directory : string;
  parent : string option;
  entries : addon_catalog_entry list;
}

type addon_package_preview = {
  manifest_path : string;
  id : string;
  revision : string;
  title : string;
  ui_category : string option;
  execution_kind : string;
  image_name : string option;
  image_state : string option;
  exported_tools : string list;
  contributions : string list;
  command : string list;
  directory : string option;
}

val decode_addon_package_catalog :
  Yojson.Safe.t -> (addon_package_catalog, string) result
val decode_addon_package_preview :
  Yojson.Safe.t -> (addon_package_preview, string) result

type connector_name_mapping = {
  id : string;
  name : string;
}

type connector_names_page = {
  connector_id : string;
  kind : string;
  total : int;
  has_more : bool;
  mappings : connector_name_mapping list;
}

val decode_connector_names_page :
  Yojson.Safe.t -> (connector_names_page, string) result

(** {1 Wave 4 Layer 2: Tool Quality, Keeper Waiting Inventory & Stateless MCP 2026-07-28} *)

type tool_quality_tool_row = {
  name : string;
  calls : int;
  success_pct : float;
  avg_ms : float;
  output_truncated_count : int;
  avg_output_chars : float;
}

type tool_quality_rate_row = {
  name : string;
  calls : int;
  success_pct : float;
}

type tool_quality_failure_cat = {
  category : string;
  count : int;
}

type tool_quality_snapshot = {
  generated_at : string;
  sampling_mode : string;
  total : int;
  success : int;
  failure : int;
  deferred : int;
  unsettled : int;
  malformed : int;
  success_rate : float;
  by_tool : tool_quality_tool_row list;
  by_keeper : tool_quality_rate_row list;
  by_runtime : tool_quality_rate_row list;
  failure_categories : tool_quality_failure_cat list;
}

val decode_tool_quality : Yojson.Safe.t -> (tool_quality_snapshot, string) result

type keeper_waiting_row = {
  keeper_name : string option;
  source : string;
  waiting_on : string;
  what : string;
  wake_producer : string;
  since : float option;
  due_at : float option;
  next_action : string;
}

type keeper_waiting_inventory = {
  schema : string;
  keeper_count : int;
  waiting_keeper_count : int;
  row_count : int;
  total_row_count : int;
  oldest_age_seconds : float option;
  rows : keeper_waiting_row list;
}

val decode_keeper_waiting_inventory :
  Yojson.Safe.t -> (keeper_waiting_inventory, string) result

val mcp_headers :
  method_:string -> ?tool_name:string -> unit -> (string * string) list
(** Required HTTP headers for stateless MCP [2026-07-28] [POST /mcp], including
    [Accept], [MCP-Protocol-Version], [Mcp-Method], optional [Mcp-Name], and
    [X-Masc-Force-Json: true]. *)

val encode_mcp_tools_list_body : id:int -> Yojson.Safe.t

val encode_mcp_tools_call_body :
  id:int -> tool_name:string -> arguments:Yojson.Safe.t -> Yojson.Safe.t

type mcp_tool_schema_entry = {
  name : string;
  description : string option;
  input_schema : Yojson.Safe.t;
  required_params : string list;
  param_names : string list;
}

val decode_mcp_tools_list :
  Yojson.Safe.t -> (mcp_tool_schema_entry list, string) result

type mcp_tool_call_result = {
  tool_name : string;
  is_error : bool;
  content_texts : string list;
  structured_json : Yojson.Safe.t option;
  raw_error : string option;
}

val decode_mcp_tools_call_result :
  tool_name:string -> Yojson.Safe.t -> (mcp_tool_call_result, string) result
