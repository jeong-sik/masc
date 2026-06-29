(** Server_dashboard_http_runtime_info — runtime
    resolution + dashboard tools projections extracted
    from the dashboard HTTP facade.

    [Server_dashboard_http] does
    [include Server_dashboard_http_runtime_info], so
    everything reached unqualified through the facade
    must be exposed here.  Pre-flight runtime grep
    (cycle 218 lesson) confirms only
    {!runtime_resolution_json} escapes to the runtime
    chain unqualified; the remaining surface is reached
    via [Server_dashboard_http.X] qualified calls or via
    a [module Runtime = ...] alias inside
    [test/test_dashboard_cache].

    External surface:
    - {b runtime resolution + HTTP routes}
      ({!runtime_resolution_json},
      {!light_runtime_resolution_json},
      {!Server_runtime_probe.dashboard_runtime_probe_http_json},
      {!runtime_inventory_json},
      {!dashboard_perf_http_json},
      {!dashboard_tools_http_json}).
    - {b runtime probe test seams}
      ({!Server_runtime_probe.set_dashboard_runtime_probe_runner_for_tests},
      {!Server_runtime_probe.clear_dashboard_runtime_probe_runner_for_tests},
      {!Server_runtime_probe.dashboard_runtime_probe_payload_json_for_tests},
      {!set_dashboard_runtime_provider_http_get_for_tests},
      {!clear_dashboard_runtime_provider_http_get_for_tests},
      {!Server_runtime_probe.clear_dashboard_runtime_probe_cache_for_tests}).
    - {b git rev-parse short test seams}
    - {b upstream tracking-ref test seams}

    Internal helpers stay private at this boundary:
    local string/list helpers, runtime probe cache state,
    git rev-parse cache state, and JSON sub-renderers used
    by the surface entries above.  The
    {!dashboard_perf_http_json} implementation delegates to
    [Server_dashboard_http_perf]. *)

(** {1 Runtime resolution} *)

val runtime_resolution_json : Workspace.config -> Yojson.Safe.t
(** Renders the runtime resolution envelope: build
    identity + workspace / base-path commit shas (via
    {!git_rev_parse_short}) + server/workspace path
    mismatch visibility + base-path resolution inputs.
    Reached unqualified through the
    [Server_dashboard_http_core] runtime consumer. *)

val light_runtime_resolution_json : Workspace.config -> Yojson.Safe.t
(** Renders the cheap runtime/fleet subset used by
    [/api/v1/dashboard/shell?light=true].  This keeps the shell health strip
    aligned with [/health] fleet safety without running git probes or other
    heavy runtime-resolution checks on the header hot path. *)

val server_workspace_mismatch_for_tests :
  server_repo_path:string -> Workspace.config -> bool
(** Test-only pure seam for the server-checkout/base-path relation used by
    {!runtime_resolution_json} and {!light_runtime_resolution_json}. It mirrors
    production normalization without touching fleet or runtime-health state. *)

(** {1 Dashboard HTTP routes} *)


val governance_hitl_json : unit -> Yojson.Safe.t
(** Returns the human-in-the-loop governance state surfaced inside
    {!runtime_resolution_json} (schema [masc.governance_hitl.v1]): whether HITL is
    [enabled] (the fail-closed [Env_config_core.disable_hitl] default), the
    [disable_env_key], and the production confirm thresholds from
    {!Governance_pipeline}. Pure read of config + governance policy; surfaces the
    "whether and why" so operators do not have to infer it from the environment. *)

val runtime_inventory_json : unit -> Yojson.Safe.t
(** Returns the materialized runtime.toml inventory loaded by
    {!Runtime.init_default}. This is the dashboard-compatible projection for
    the legacy [/api/v1/providers] route; it does not execute providers or
    infer defaults outside the Runtime SSOT. The envelope includes
    [assignment_governance] so operators can see explicit keeper-runtime
    assignment blast radius without the dashboard parsing TOML independently. *)

val dashboard_perf_http_json : Workspace.config -> Yojson.Safe.t
(** Renders the dashboard performance envelope (build
    identity, runtime / workspace commits, system clock
    skew, etc). *)

val dashboard_tools_http_json :
  ?actor:string ->
  ?timing:Server_timing.t ->
  Workspace.config ->
  Yojson.Safe.t
(** Renders the dashboard tools projection.  [?actor]
    selects the per-agent tool catalogue when present;
    otherwise the full registry surface is returned.  When [?timing] is
    provided, internal phases (config_resolution, runtime_resolution,
    tools_compute) are accumulated into the [Server_timing.t] for surfacing
    via the [Server-Timing] response header. *)

(** Renders the read-only dashboard projection for scheduled internal
    automation. This summarizes the schedule store as a small FSM envelope
    plus recent request rows; it does not refresh due state or run work. *)
