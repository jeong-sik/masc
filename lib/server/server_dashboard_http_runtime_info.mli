(** Server_dashboard_http_runtime_info — runtime
    resolution + dashboard tools projections extracted
    from the dashboard HTTP facade.

    [Server_dashboard_http] does
    [include Server_dashboard_http_runtime_info], so
    everything reached unqualified through the facade
    must be exposed here.  Pre-flight cascade grep
    (cycle 218 lesson) confirms only
    {!runtime_resolution_json} escapes to the cascade
    chain unqualified; the remaining surface is reached
    via [Server_dashboard_http.X] qualified calls or via
    a [module Runtime = ...] alias inside
    [test/test_dashboard_cache].

    External surface (13 entries):
    - {b runtime resolution + HTTP routes}
      ({!runtime_resolution_json},
      {!dashboard_runtime_probe_http_json},
      {!dashboard_perf_http_json},
      {!dashboard_tools_http_json}).
    - {b runtime probe test seams}
      ({!set_dashboard_runtime_probe_runner_for_tests},
      {!clear_dashboard_runtime_probe_runner_for_tests},
      {!clear_dashboard_runtime_probe_cache_for_tests}).
    - {b git rev-parse short test seams}
      ({!git_rev_parse_short},
      {!git_rev_parse_short_probe_argv},
      {!set_git_rev_parse_short_probe_hook_for_tests},
      {!clear_git_rev_parse_short_probe_hook_for_tests},
      {!clear_git_rev_parse_short_cache_for_tests},
      {!seed_git_rev_parse_short_cache_for_tests}).

    Internal helpers stay private at this boundary
    (~57 internal lets — [contains_substring] / [take]
    local helpers, [trim_to_option] / [list_hd_opt],
    [path_descends_from] / [path_relative_to],
    [dashboard_runtime_probe_*] cache state +
    refresh-in-flight Atomic + runner hook ref +
    [dashboard_runtime_probe_cache_ttl_sec] /
    [dashboard_runtime_probe_force_min_refresh_sec] /
    [dashboard_runtime_probe_timeout_sec] tuning,
    [dashboard_runtime_probe_recent_value] /
    [dashboard_runtime_probe_fresh_value] cache
    accessors, [dashboard_runtime_probe_runner_hook] +
    runner adapter, [git_rev_parse_short_*] cache state
    (mutex, in-flight set, TTL, cached_lookup,
    cached_any, try_begin_refresh), all the
    [dashboard_*_json] sub-renderers consumed only
    inside the surface entries above). *)

(** {1 Runtime resolution} *)

val runtime_resolution_json : Coord.config -> Yojson.Safe.t
(** Renders the runtime resolution envelope: build
    identity + workspace / base-path commit shas (via
    {!git_rev_parse_short}) + base-path resolution
    inputs.  Reached unqualified through the
    [Server_dashboard_http_core] cascade consumer. *)

(** {1 Dashboard HTTP routes} *)

val dashboard_runtime_probe_http_json :
  ?force:bool -> unit -> Yojson.Safe.t
(** Returns the dashboard runtime-probe envelope.  With
    [?force:true], bypasses the per-call freshness gate
    and falls back to the recent-value gate; with
    [?force:false] (default), skips the read entirely
    when a fresh cache value is available.  Output
    includes a [cache_hit] flag so dashboards can show
    the freshness state. *)

val dashboard_perf_http_json : Coord.config -> Yojson.Safe.t
(** Renders the dashboard performance envelope (build
    identity, runtime / workspace commits, system clock
    skew, etc). *)

val dashboard_tools_http_json :
  ?actor:string -> Coord.config -> Yojson.Safe.t
(** Renders the dashboard tools projection.  [?actor]
    selects the per-agent tool catalogue when present;
    otherwise the full registry surface is returned. *)

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

val clear_dashboard_runtime_probe_cache_for_tests :
  unit -> unit
(** Drops the cached runtime-probe value AND clears the
    refresh-in-flight gate so the next call observes a
    fresh state machine. *)

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
