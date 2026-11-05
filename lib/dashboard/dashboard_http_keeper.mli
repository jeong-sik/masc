(** Dashboard_http_keeper — keepers_dashboard_json
    rendering: per-keeper metrics series, conversation
    history, memory bank, diagnostic
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
    message history / memory bank /
    diagnostic summaries, the rollup sub-counters
    ([succ_*] / [fail_*]), the model / capability /
    backend resolvers, and the
    [Keeper_transition_audit] adapters). *)

(** {1 Runtime re-exports for [Server_dashboard_http_core]}

    [Server_dashboard_http_core] does
    [include Dashboard_http_keeper], so every symbol it
    reaches unqualified must be exposed here. *)

val keeper_count : Workspace.config -> int option
(** Total keepers visible in [config.base_path] meta; [None] when the Keeper
    directory did not list. *)

val configured_keeper_count : Workspace.config -> int
(** Number of distinct keeper names discovered from [*.toml] in the keepers
    config dir. Every file counts, including ones that fail to load (their name
    falls back to the filename stem); no filename or [activation_mode]
    filtering happens here. The materializability-filtered view is
    [materializable_configured_keeper_names] in
    [server_routes_http_runtime_fleet_scan]. *)

val running_keeper_count : Workspace.config -> int
(** Counts keepers whose meta indicates an active
    keep-alive runtime.  Used by the dashboard fleet
    summary on the runtime consumer side. *)

(** {1 Outcomes rollup} *)

val compute_outcomes_rollup :
  base_path:string ->
  keeper_name:string ->
  agent_name:string ->
  recent_crash_count:int ->
  registry_entry:Keeper_registry.registry_entry option ->
  Yojson.Safe.t
(** Aggregates the keeper's last 50 completed turns into
    a JSON rollup of success / failure counters
    (turns / handoffs / gate rejections).
    [recent_crash_count] is folded in as an additional
    failure axis; [registry_entry] supplies metadata
    (active model and other runtime metadata) when present. *)

(** {1 Dashboard producers} *)

val keepers_dashboard_json :
  ?compact:bool -> Workspace.config -> Yojson.Safe.t
(** Renders the full keepers dashboard envelope.  With
    [~compact:true] (default [false]), per-keeper
    payloads drop the deep history / memory-bank /
    metrics-series sections and keep only the high-level
     summary row used by the lightweight overview pane.

     [current_gate] comes from one lock-consistent workspace approval-queue
     snapshot, selecting the Keeper's newest pending admission by sequence.
     Audit rows remain historical observations and cannot reopen a resolved
     request. An unavailable or partially unreadable queue publishes a null
     [current_gate] with an unavailable [approval_queue_state]; a confirmed
     empty queue publishes the ready state. [approval_audit_state] separately
     reports whether the historical audit read succeeded. *)

val execution_trust_dashboard_json : Workspace.config -> Yojson.Safe.t
(** Renders the execution-trust dashboard surface.  Folds
    every keeper's recent turns + capability metadata
    into a single JSON envelope used by the
    [Server_dashboard_http_execution_surfaces] cache. *)

val keeper_cost_aggregates_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  window_minutes:int ->
  now_ts:float ->
  Yojson.Safe.t
(** Renders per-keeper cost and latency aggregates for the provider dashboard. *)

val keeper_decisions_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
(** Renders a recent unified keeper decision/event stream. *)

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

module For_test : sig
  val current_gate_fields_for_workspace :
    base_path:string -> keeper_name:string -> now_ts:float ->
    (string * Yojson.Safe.t) list
  (** The same current Gate projection used by {!keepers_dashboard_json},
      reading the actual workspace queue snapshot. *)

  val keeper_row_after_worker_failure :
    Workspace.config -> name:string -> error:string -> Yojson.Safe.t
  (** The row a keeper gets in [keepers_dashboard_json] and
      [execution_trust_dashboard_json] after its worker raised [error]. It is
      the degraded row when the meta is present and building it succeeds;
      otherwise a row carrying only the name and the errors (meta absent, not
      current or unreadable, or the degraded row itself raised). Never
      absent. *)
end
