(** Dashboard_http_keeper — keepers_dashboard_json
    rendering: per-keeper metrics series, 24h buckets,
    conversation history, memory bank, diagnostic
    summaries, and the execution-trust + keeper-config
    surfaces.

    External surface (4 entries) — every dotted caller
    reaches one of these and nothing else:
    - {b dashboard producers}
      ({!keepers_dashboard_json},
      {!execution_trust_dashboard_json}) consumed by the
      dashboard execution test and the dashboard HTTP
      execution-surfaces facade.
    - {b per-keeper runtime snapshot} ({!keeper_config_json})
      consumed by [server_dashboard_http_keeper_api].
    - {b outcomes rollup} ({!compute_outcomes_rollup})
      consumed by [test/test_dashboard_harness_health].

    Internal helpers stay private at this boundary
    (everything else — see the 1700-line .ml.  Notably:
    every per-section sub-renderer for metrics series /
    24h buckets / message history / memory bank /
    diagnostic summaries, the rollup sub-counters
    ([succ_*] / [fail_*]), the model / capability /
    backend resolvers, and the
    [Keeper_transition_audit] adapters). *)

(** {1 Runtime re-exports for [Server_dashboard_http_core]}

    [Server_dashboard_http_core] does
    [include Dashboard_http_keeper], so every symbol it
    reaches unqualified must be exposed here. *)

val keeper_count : Workspace.config -> int
(** Compatibility count of keepers visible in [config.base_path] meta.  Use
    {!keeper_count_scan} when the caller must surface discovery failures. *)

type keeper_count_scan = {
  keeper_count : int;
  keeper_count_known : bool;
  keeper_count_read_errors : Yojson.Safe.t list;
}

val keeper_count_scan : Workspace.config -> keeper_count_scan
(** Counts keepers visible in [config.base_path] meta and preserves the
    keeper-name discovery read errors that make the count non-authoritative. *)

val configured_keeper_count : Workspace.config -> int
(** Total materializable declarative runtime keeper profiles discovered from
    keeper TOML. Loader-level templates are excluded only when they do not opt
    into runtime materialization, e.g. via [autoboot_enabled=true]. *)

val keeper_names : Workspace.config -> string list
(** Keeper names visible in [config.base_path] meta. *)

val running_keeper_count : Workspace.config -> int
(** Compatibility count of keepers whose meta indicates an active keep-alive
    runtime.  Use {!running_keeper_count_scan} when the caller must surface
    unreadable keeper meta. *)

type running_keeper_count_scan = {
  running_keeper_count : int;
  running_keeper_count_known : bool;
  running_keeper_count_read_errors : Yojson.Safe.t list;
}

val running_keeper_count_scan : Workspace.config -> running_keeper_count_scan
(** Counts keepers whose meta indicates an active keep-alive runtime and
    reports name-discovery or per-keeper meta read errors instead of collapsing
    them into an authoritative zero. *)

(** {1 Outcomes rollup} *)

val compute_outcomes_rollup :
  keeper_name:string ->
  agent_name:string ->
  recent_crash_count:int ->
  registry_entry:Keeper_registry.registry_entry option ->
  Yojson.Safe.t
(** Aggregates the keeper's last 50 completed turns into
    a JSON rollup of success / failure counters
    (turns / compactions / handoffs / gate rejections).
    [recent_crash_count] is folded in as an additional
    failure axis; [registry_entry] supplies metadata
    (active model, persona role, etc) when present. *)

(** {1 Dashboard producers} *)

val keepers_dashboard_json :
  ?compact:bool -> Workspace.config -> Yojson.Safe.t
(** Renders the full keepers dashboard envelope.  With
    [~compact:true] (default [false]), per-keeper
    payloads drop the deep history / memory-bank /
    metrics-series sections and keep only the high-level
    summary row used by the lightweight overview pane. *)

val execution_trust_dashboard_json : Workspace.config -> Yojson.Safe.t
(** Renders the execution-trust dashboard surface.  Folds
    every keeper's recent turns + capability metadata
    into a single JSON envelope used by the
    [Server_dashboard_http_execution_surfaces] cache. *)

val keeper_cost_aggregates_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  window_minutes:int ->
  Yojson.Safe.t
(** Renders per-keeper cost and latency aggregates for the provider dashboard. *)

val keeper_decisions_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
(** Renders a recent unified keeper decision/event stream. *)

val keeper_decisions_log_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
(** Renders the K2 cross-keeper decision log feed. *)

val keeper_memory_log_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
(** Renders the K2 cross-keeper memory-bank feed. *)

(** {1 Per-keeper runtime snapshots} *)

val keeper_config_json :
  Workspace.config ->
  string ->
  [ `OK | `Not_found ] * Yojson.Safe.t
(** Returns the keeper's effective configuration JSON
    (resolved model, allowed tools, runtime limits,
    runtime settings).  Pairs with a status tag —
    [`Not_found] when [Keeper_meta_store.read_meta] fails or
    returns [None], [`OK] otherwise.  The handler avoids
    [bootstrap_runtime] mutations to keep the HTTP
    request path off the keeper-meta mutex (#3335). *)
