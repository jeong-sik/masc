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
      {!dashboard_runtime_probe_http_json},
      {!dashboard_runtime_probe_payload_json_of_runtimes},
      {!runtime_inventory_json},
      {!dashboard_tools_http_json}).
    - {b runtime probe test seams}
      ({!set_dashboard_runtime_probe_runner_for_tests},
      {!clear_dashboard_runtime_probe_runner_for_tests},
      {!set_dashboard_runtime_provider_http_get_for_tests},
      {!clear_dashboard_runtime_provider_http_get_for_tests},
      {!clear_dashboard_runtime_probe_cache_for_tests}).
    - {b git rev-parse short test seams}
      ({!git_rev_parse_short},
      {!git_rev_parse_short_probe_argv},
      {!set_git_rev_parse_short_probe_hook_for_tests},
      {!clear_git_rev_parse_short_probe_hook_for_tests},
      {!clear_git_rev_parse_short_cache_for_tests},
      {!seed_git_rev_parse_short_cache_for_tests}).
    - {b upstream tracking-ref test seams}
      ({!git_upstream_status},
      {!set_git_upstream_status_probe_hook_for_tests},
      {!clear_git_upstream_status_probe_hook_for_tests}).

    Internal helpers stay private at this boundary:
    local string/list helpers, runtime probe cache state,
    git rev-parse cache state, and JSON sub-renderers used
    by the surface entries above. *)

(** {1 Runtime resolution} *)

val runtime_resolution_json : Workspace.config -> Yojson.Safe.t
(** Renders the runtime resolution envelope: build
    identity + workspace / base-path commit shas (via
    {!git_rev_parse_short}) + server/workspace path
    mismatch visibility + base-path resolution inputs.
    Reached unqualified through the
    [Server_dashboard_http_core] runtime consumer. *)

val light_runtime_resolution_json :
  ?profile_snapshot:Keeper_types_profile.keeper_profile_snapshot ->
  Workspace.config -> Yojson.Safe.t
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

val dashboard_runtime_probe_http_json :
  ?force:bool -> unit -> Yojson.Safe.t
(** Returns the dashboard runtime-probe envelope with the probe loop's latest
    value ({!start_dashboard_runtime_probe_loop}). No read runs a probe.

    [?force:true] (the dashboard "Live probe" button) serves a value younger
    than [dashboard_runtime_probe_force_min_refresh_sec] as it is; past that
    window it wakes the loop and serves the value it has. The probe it asked
    for is announced as [runtime_probe] when it lands.

    Output fields:
    - [cache_hit]: the value is inside the window the read asked for.
    - [refresh_state]: one of [fresh] (younger than the TTL), [recent]
      (force=1 inside the recent window), [served_stale] (older than the
      window: the loop is probing, or this forced read woke it), or
      [warming_up] (no probe has landed since the server started). *)

val dashboard_runtime_probe_failure_envelope_of_exn :
  exn -> Yojson.Safe.t
(** Pure builder for the failure envelope persisted to the cache when a
    probe raises ([probe_ok=false], status [unreachable], the
    exception message in [errors]). Exposed so the failure-visibility contract
    is unit-testable independent of the cache/atomic plumbing. *)

val start_dashboard_runtime_probe_loop :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> base_path:string -> unit
(** Probes the runtimes now, then every [dashboard_runtime_probe_cache_ttl_sec]
    and whenever a forced read asks, keeping the latest value for
    {!dashboard_runtime_probe_http_json}. A probe a read asked for is announced
    as [runtime_probe]; a periodic one when what it found differs from the
    last probe, the times it was checked aside. A probe that raises keeps
    {!dashboard_runtime_probe_failure_envelope_of_exn} as the value. *)

val dashboard_runtime_probe_payload_json_of_runtimes :
  ?default_id:string -> Runtime_instance.t list -> Yojson.Safe.t
(** Pure reachability-probe projection over an explicit [Runtime_instance.t list].
    Exactly one metadata request is made per provider; its observation is
    projected onto each model/runtime row so callers keep the runtime-shaped
    schema without multiplying identical endpoint probes.
    Static authentication and non-auth headers come from the selected HTTP
    execution; admission uses the same runtime's captured credential authority.
    This observation does not reselect Env/File credentials. Fresh selection
    belongs to runtime materialization or explicit model discovery. Vertex
    native-auth and official-client probes retain their stated skips.
    [auth_kind] describes the declared credential reference; [auth_present]
    observes the selected request headers.
    [run_dashboard_runtime_probe] calls this with the live runtime fleet;
    exposed directly (rather than via a [_for_tests] alias) so tests can drive
    it with synthetic runtimes. HTTP execution is supplied by the production
    GET path or, in tests, {!set_dashboard_runtime_provider_http_get_for_tests}. *)

val gate_hitl_json : unit -> Yojson.Safe.t
(** Returns the always-available, nonblocking human-decision handler state
    surfaced inside {!runtime_resolution_json}. *)

val runtime_inventory_json : unit -> Yojson.Safe.t
(** HTTP runtime rows expose [provider_admission]: [declared_max] and
    [enforced_for_runtime] describe this runtime's admission policy; [snapshot]
    is current process-local endpoint/credential scheduler state, or [null]
    if none has been observed. A bypassing config can share an identity with
    another config's scheduler. Shared snapshots across rows must not be summed.
    Official-client runtime rows expose [provider_admission=null]. *)
(** Returns the materialized runtime.toml inventory loaded by
    {!Runtime.init_default}. This is the dashboard-compatible projection for
    the legacy [/api/v1/providers] route; it does not execute providers or
    infer defaults outside the Runtime SSOT. The envelope includes
    [assignment_status] so operators can see explicit keeper-runtime
    assignment blast radius without the dashboard parsing TOML independently. *)

val invalidate_dashboard_tools : base_path:string -> unit
(** Retire the shared HTTP query cache before a successful source-owned Tools
    publication, including pending computations and exact-Keeper fallbacks. *)

val dashboard_tools_http_result :
  ?read_policy:Dashboard_projection_read.t ->
  ?keeper:string ->
  ?timing:Server_timing.t ->
  Workspace.config ->
  Dashboard_snapshot.tools_result
(** The final decorated tools response with producer-owned readiness. Its
    classification travels with the returned cache payload, so a concurrent
    fill cannot promote an already-returned warming response. [Current] reads
    directly on the caller's worker, bypassing the private TTL and any pending
    HTTP cache fill. Ordinary HTTP readers default to [Reuse]. *)

val dashboard_tools_http_json :
  ?keeper:string ->
  ?timing:Server_timing.t ->
  Workspace.config ->
  Yojson.Safe.t
(** Renders the registered catalog plus, when [?keeper] is supplied, the
    exact effective dynamic-tool surface for that Keeper. When [?timing] is
    provided, internal phases (config_resolution, runtime_resolution,
    tools_compute) are accumulated into the [Server_timing.t] for surfacing
    via the [Server-Timing] response header. *)

(** {1 Runtime-probe test seams} *)

val set_dashboard_runtime_probe_runner_for_tests :
  (unit -> Yojson.Safe.t) -> unit
(** Installs a synthetic runner that supplies a
    deterministic probe payload.  Test-only seam — the
    production runner forks a sub-process. *)

val clear_dashboard_runtime_probe_runner_for_tests :
  unit -> unit
(** Removes the test runner installed by
    {!set_dashboard_runtime_probe_runner_for_tests}. *)

val set_dashboard_runtime_provider_http_get_for_tests :
  (url:string ->
   headers:(string * string) list ->
   timeout_sec:float ->
   (int * (string * string) list * string, string) result) ->
  unit
(** Installs a deterministic HTTP GET hook used by the provider reachability
    probe.  The hook receives the final probe URL and in-memory headers; callers
    must not persist header values in assertion failure messages. *)

val clear_dashboard_runtime_provider_http_get_for_tests :
  unit -> unit
(** Removes the provider HTTP GET hook installed by
    {!set_dashboard_runtime_provider_http_get_for_tests}. *)

val clear_dashboard_runtime_probe_cache_for_tests :
  unit -> unit
(** Drops the cached runtime-probe value AND clears the
    refresh-in-flight gate so the next call observes a
    fresh state machine. *)

val set_dashboard_runtime_probe_cache_for_tests :
  probe:Yojson.Safe.t -> age_sec:float -> unit -> unit
(** Seeds the runtime-probe cache with [probe], aged [age_sec] seconds. Drives
    the fresh ([age_sec] < TTL, non-force) / recent ([age_sec] < force window,
    force=1) / stale (older than both) branches of
    {!dashboard_runtime_probe_http_json} deterministically, since unit tests
    have no Eio switch for a real background refresh. *)

(** {1 Git rev-parse short test seams + helper} *)

val git_rev_parse_short : string -> string option
(** Returns the short commit sha for the repository at
    [path].  [None] for empty / non-existent paths,
    failed [git] invocations, or non-repository
    directories.  Cached for
    [git_rev_parse_short_ttl_sec] (60 s) per directory;
    misses go through a sandboxed [git rev-parse
    --short HEAD] subprocess with a 15 s timeout
    (#9765 / #9775). *)

val git_rev_parse_short_probe_argv : string -> string list
(** Returns the [argv] used by the production probe to
    invoke [git rev-parse --short HEAD].  Pinned because
    [test/test_dashboard_cache] asserts on the exact
    argv shape to guard against accidental flag drift. *)

val git_probe_command_available :
  ?getenv:(string -> string option) -> unit -> bool
(** Shell-free capability check shared by the rev-parse and upstream probes.
    A deployment without Git returns [false] before either probe spawns a
    process. [getenv] is injectable for deterministic tests. *)

val set_git_rev_parse_short_probe_hook_for_tests :
  (string -> string option) -> unit
(** Installs a hook that bypasses the production
    [git] subprocess.  Test-only seam. *)

val clear_git_rev_parse_short_probe_hook_for_tests :
  unit -> unit
(** Removes the test hook installed by
    {!set_git_rev_parse_short_probe_hook_for_tests}. *)

val clear_git_rev_parse_short_cache_for_tests : unit -> unit
(** Drops the cached commit-sha lookups AND the
    in-flight refresh set under the cache mutex. *)

val seed_git_rev_parse_short_cache_for_tests :
  string -> string option -> refreshed_at:float -> unit
(** Seeds the cache with [(dir, value, refreshed_at)]
    so the next {!git_rev_parse_short} call against
    [dir] reads the seeded value (subject to TTL). *)

type git_upstream_status = Server_dashboard_http_runtime_info_json.git_upstream_status = {
  branch : string option;
  upstream_ref : string option;
  upstream_head_commit : string option;
  ahead_count : int option;
  behind_count : int option;
}
(** Local tracking-ref status for the server checkout.  This deliberately
    uses only already-fetched refs such as [@{upstream}] and does not perform
    network access. *)

val git_upstream_status : string -> git_upstream_status option
(** Returns local tracking-ref status for [path].  Detached checkouts fall back
    to [refs/remotes/origin/HEAD] when [@{upstream}] is unavailable, still
    without fetching from the network.  Cached for 60 s per directory; stale
    values are served while a background refresh is in flight. *)

val set_git_upstream_status_probe_hook_for_tests :
  (string -> git_upstream_status option) -> unit
(** Installs a test-only hook for upstream tracking-ref probes. *)

val clear_git_upstream_status_probe_hook_for_tests : unit -> unit
(** Removes the hook installed by
    {!set_git_upstream_status_probe_hook_for_tests}. *)

val clear_git_upstream_status_cache_for_tests : unit -> unit
(** Drops cached upstream-status lookups AND the in-flight refresh set under
    the cache mutex. *)

val seed_git_upstream_status_cache_for_tests :
  string -> git_upstream_status option -> refreshed_at:float -> unit
(** Seeds the upstream-status cache for [path] so tests can exercise stale-first
    refresh behavior without waiting for wall-clock TTL expiry. *)
