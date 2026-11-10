(** Dashboard_http_keeper — the execution-trust dashboard surface and the
    keeper counts and config snapshot the dashboard routes read.

    - {b dashboard producer} ({!execution_trust_dashboard_json}) consumed by
      the dashboard HTTP execution-surfaces facade.
    - {b per-keeper runtime snapshot} ({!keeper_config_json}) consumed by
      [server_dashboard_http_keeper_api]. *)

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

(** {1 Dashboard producers} *)

val execution_trust_dashboard_json : Workspace.config -> Yojson.Safe.t
(** Renders the execution-trust dashboard surface.  Folds
    every keeper's recent turns + capability metadata
    into a single JSON envelope used by the
    [Server_dashboard_http_execution_surfaces] cache. *)

val execution_trust_dashboard_observation :
  Workspace.config -> Yojson.Safe.t * float option
(** The same source read together with its next receipt-freshness deadline.
    The deadline is computed from the same receipt timestamp, count and gap
    observation used to render [health], before encoding any wire fields. *)

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
  val keeper_row_after_worker_failure :
    Workspace.config -> name:string -> error:string -> Yojson.Safe.t
  (** The row a keeper gets after its worker raised [error];
      [execution_trust_dashboard_json] narrows it to the execution-trust
      fields. It is the degraded row when the meta is present and building it
      succeeds;
      otherwise a row carrying only the name and the errors (meta absent, not
      current or unreadable, or the degraded row itself raised). Never
      absent. *)
end
