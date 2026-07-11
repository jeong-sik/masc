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
      {!runtime_inventory_json},
      {!dashboard_perf_http_json},
      {!scheduled_automation_dashboard_json},
      {!dashboard_tools_http_json}).
    - {b runtime probe test seams}
      ({!set_dashboard_runtime_probe_runner_for_tests},
      {!clear_dashboard_runtime_probe_runner_for_tests},
      {!dashboard_runtime_probe_payload_json_for_tests},
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

val dashboard_runtime_probe_http_json :
  ?force:bool -> unit -> Yojson.Safe.t
(** Returns the dashboard runtime-probe envelope. The route never blocks: on a
    cache hit it returns the cached value; on a miss it schedules a non-blocking
    background refresh and returns the best value available now (a stale cache
    value, or a cold-start warming-up placeholder).

    [?force:true] (the dashboard "Live probe" button) bypasses the per-call TTL
    gate and uses the shorter recent-value window
    ([dashboard_runtime_probe_force_min_refresh_sec]); past that window it still
    only schedules a background refresh — it does NOT block for an immediate
    fresh probe. Callers that expect "force = instant fresh value" must instead
    read [refresh_state] and re-poll.

    Output fields:
    - [cache_hit]: the returned [probe] came from cache (it was not freshly
      scheduled this call).
    - [refresh_state]: one of [fresh] (TTL-fresh hit), [recent] (force=1 inside
      the recent window), [served_stale] (stale value returned + background
      refresh scheduled), or [warming_up] (cold-start placeholder + background
      refresh scheduled). [served_stale]/[warming_up] mean the refreshed value
      arrives on the next poll. *)

val dashboard_runtime_probe_failure_envelope_of_exn :
  exn -> Yojson.Safe.t
(** Pure builder for the failure envelope persisted to the cache when a
    background refresh raises ([probe_ok=false], status [unreachable], the
    exception message in [errors]). Exposed so the failure-visibility contract
    is unit-testable independent of the cache/atomic plumbing. *)

val maybe_fork_dashboard_runtime_probe_refresh : unit -> unit
(** Schedule a non-blocking background refresh of the runtime-probe cache.
    Single-flight via an internal CAS: a no-op when a refresh is already
    running, when no server switch is reachable, or on Domain_pool worker
    domains where a background [Eio.Fiber.fork] is not permitted. Called by
    {!dashboard_runtime_probe_http_json} on cache miss / soft-TTL expiry, and by
    the server boot path to warm the cache before the first dashboard request
    so the first response is not a [warming_up] placeholder. *)

val dashboard_runtime_probe_payload_json_for_tests :
  ?default_id:string -> Runtime.t list -> Yojson.Safe.t
(** Test-only pure projection for the production runtime reachability payload.
    HTTP execution is supplied through
    {!set_dashboard_runtime_provider_http_get_for_tests}. *)

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

val scheduled_automation_dashboard_json : Workspace.config -> Yojson.Safe.t
(** Renders the read-only dashboard projection for scheduled internal
    automation. This summarizes the schedule store as a small FSM envelope
    plus recent request rows; it does not refresh due state or run work. *)

type schedule_execution_history_page_error =
  | Schedule_execution_history_invalid_limit of int
  | Schedule_execution_history_schedule_not_found of string
  | Schedule_execution_history_cursor_not_found of string
  | Schedule_execution_history_store_read_error of Schedule_store.read_error

val schedule_execution_history_page_error_to_string :
  schedule_execution_history_page_error -> string

val schedule_execution_history_page_json :
  config:Workspace.config ->
  schedule_id:string ->
  cursor:string option ->
  limit:int ->
  (Yojson.Safe.t, schedule_execution_history_page_error) result
(** Returns one immutable newest-first page from the durable schedule execution
    ledger. [cursor] is the last execution id already held by the caller; the
    next page begins strictly after it. Missing schedules, stale cursors, and
    corrupt ledgers are explicit errors rather than empty history. *)

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

type git_upstream_status = {
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
