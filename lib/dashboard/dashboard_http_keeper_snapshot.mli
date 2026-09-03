(** Dashboard_http_keeper_snapshot — per-keeper config rendering and K2 feed
    delegations.

    Extracted from [dashboard_http_keeper.ml] during godfile decomposition. *)

val keeper_config_json :
  Workspace.config ->
  string ->
  [ `OK | `Not_found ] * Yojson.Safe.t
(** [keeper_config_json config name] renders the named keeper's effective
    configuration as JSON, paired with [`Not_found] when
    [Keeper_meta_store.read_meta] fails or returns [None] and [`OK] otherwise.

    The [`OK] object has two shapes. When the keeper's profile defaults load
    and [Keeper_meta_contract.effective_meta_of_profile_defaults] succeeds, the
    full configuration is rendered. When either step fails the result is still
    [`OK], and the object carries [name], [config_revision],
    [effective_config] = null, [config_error] and [sources] — no sandbox keys
    at all. Callers must treat [sandbox_profile] and [remote_endpoint] as
    absent on that branch rather than assuming a value; the dashboard's
    [normalizeKeeperConfig] substitutes its own placeholder there
    (dashboard/src/api/dashboard-keeper-config.ts).

    In the full shape, [sandbox_profile] is one of "docker", "microvm" or
    "remote_ssh" ([Keeper_types_profile_sandbox.sandbox_profile_to_string] of
    the keeper's resolved profile). [remote_endpoint] is the endpoint name from
    the profile defaults, or null; it is read independently of the profile, so
    a docker or microvm keeper can carry one — the pairing
    [Keeper_turn_up_args.parse] refuses with
    [remote_endpoint_requires_remote_ssh]. The dashboard's config panel reads
    both keys, so removing or renaming either changes what that panel can
    save.

    Reads only; it avoids [bootstrap_runtime] mutations to keep the HTTP
    request path off the keeper-meta mutex (#3335). *)

val keeper_cost_aggregates_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  window_minutes:int ->
  Yojson.Safe.t

val keeper_decisions_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t

val keeper_decisions_log_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
