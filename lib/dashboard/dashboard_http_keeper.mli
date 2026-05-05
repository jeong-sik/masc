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
    - {b per-keeper runtime snapshots}
      ({!keeper_config_json}, {!keeper_bdi_snapshot_json}) consumed by
      [server_dashboard_http_keeper_api] +
      [test/test_operator_control_keeper].
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

(** {1 Cascade re-exports for [Server_dashboard_http_core]}

    [Server_dashboard_http_core] does
    [include Dashboard_http_keeper], so every symbol it
    reaches unqualified must be exposed here. *)

val keeper_count : Coord.config -> int
(** Total keepers visible in [config.base_path] meta. *)

val keeper_names : Coord.config -> string list
(** Keeper names visible in [config.base_path] meta. *)

val running_keeper_count : Coord.config -> int
(** Counts keepers whose meta indicates an active
    keep-alive runtime.  Used by the dashboard fleet
    summary on the cascade consumer side. *)

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
  ?compact:bool -> Coord.config -> Yojson.Safe.t
(** Renders the full keepers dashboard envelope.  With
    [~compact:true] (default [false]), per-keeper
    payloads drop the deep history / memory-bank /
    metrics-series sections and keep only the high-level
    summary row used by the lightweight overview pane. *)

val execution_trust_dashboard_json : Coord.config -> Yojson.Safe.t
(** Renders the execution-trust dashboard surface.  Folds
    every keeper's recent turns + capability metadata
    into a single JSON envelope used by the
    [Server_dashboard_http_execution_surfaces] cache. *)

val keeper_cost_aggregates_json :
  config:Coord.config ->
  keepers:Keeper_types.keeper_meta list ->
  window_minutes:int ->
  Yojson.Safe.t
(** Renders per-keeper cost and latency aggregates for the provider dashboard. *)

val keeper_decisions_json :
  config:Coord.config ->
  keepers:Keeper_types.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
(** Renders a recent unified keeper decision/event stream. *)

val keeper_decisions_log_json :
  config:Coord.config ->
  keepers:Keeper_types.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
(** Renders the K2 cross-keeper decision log feed. *)

val keeper_memory_log_json :
  config:Coord.config ->
  keepers:Keeper_types.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
(** Renders the K2 cross-keeper memory-bank feed. *)

(** {1 Per-keeper runtime snapshots} *)

val keeper_config_json :
  Coord.config ->
  string ->
  [ `OK | `Not_found ] * Yojson.Safe.t
(** Returns the keeper's effective configuration JSON
    (resolved model, allowed tools, runtime limits,
    cascade settings).  Pairs with a status tag —
    [`Not_found] when [Keeper_types.read_meta] fails or
    returns [None], [`OK] otherwise.  The handler avoids
    [bootstrap_runtime] mutations to keep the HTTP
    request path off the keeper-meta mutex (#3335). *)

val keeper_bdi_snapshot_json :
  Coord.config ->
  string ->
  [ `OK | `Not_found ] * Yojson.Safe.t
(** Returns a small live BDI snapshot for the IDE inspector rail:
    belief/desire/intention, recent token spend, and the latest tool call.
    Reads keeper meta + recent metrics/tool-call JSONL only; it does not
    mutate runtime state. *)
