(** Keeper_tool_affinity — History-based tool pre-population for small models.

    Reads trajectory JSONL for a keeper, scores tools by usage frequency,
    success rate, and recency, and returns the top-K tool names to
    pre-populate into {!Keeper_discovered_tools} at session start.

    Solves the "text_response trap" where 9B models write text about
    actions instead of calling tools, because the discovered set is empty
    on a fresh generation.

    @since 2.251.0
    @see <https://github.com/jeong-sik/masc/issues/5566> *)

type affinity_entry = {
  tool_name : string;
  score : float;
  call_count : int;
  success_rate : float;
}

val compute_affinity :
  tool_stats:Trajectory.tool_stat list ->
  now:float ->
  max_k:int ->
  affinity_entry list
(** [compute_affinity ~tool_stats ~now ~max_k] scores tools from
    trajectory stats and returns the top-[max_k] entries sorted by
    descending score.  Tools with success_rate below the threshold
    (default 0.3) are excluded. *)

val pre_populate_from_history :
  masc_root:string ->
  keeper_name:string ->
  allowed_tool_names:string list ->
  core_tool_names:string list ->
  discovered:Keeper_discovered_tools.t ->
  max_k:int ->
  affinity_entry list
(** [pre_populate_from_history] is the main entry point.
    Reads recent trajectory, computes affinity, filters by allowed/core,
    and calls {!Keeper_discovered_tools.add} for the top-K tools.
    Returns the affinity entries that were added (for logging/metrics).
    Returns [[]] if no trajectory data exists or [max_k = 0]. *)

val configured_max_k : ?getenv:(string -> string option) -> unit -> int
(** Read max_k from [MASC_KEEPER_TOOL_AFFINITY_K] env, clamped to [0, 20].
    Default: 5.  Set to 0 to disable affinity.  Empty or whitespace-only
    values are treated as unset (the codebase convention for clearing an
    env var is [Unix.putenv name ""]).
    Optional [?getenv] parameter allows mock/test-specific environment lookup. *)

val configured_lookback_days : ?getenv:(string -> string option) -> unit -> int
(** Read lookback_days from [MASC_KEEPER_TOOL_AFFINITY_LOOKBACK_DAYS] env,
    clamped to [1, 30].  Default: 7.  Empty or whitespace-only values are
    treated as unset.
    Optional [?getenv] parameter allows mock/test-specific environment lookup. *)

val resolve_affinity_aggregate :
  read_snapshot:(masc_root:string -> keeper_name:string ->
    (Trajectory.tool_affinity_aggregate, Trajectory.aggregate_load_error) result) ->
  rebuild:(masc_root:string -> keeper_name:string -> now:float ->
    Trajectory.tool_affinity_aggregate) ->
  masc_root:string ->
  keeper_name:string ->
  now:float ->
  Trajectory.tool_affinity_aggregate
(** Return the persisted aggregate when [read_snapshot] yields [Ok], else the
    result of [rebuild]. [pre_populate_from_history] wires [read_snapshot] to
    {!Trajectory.read_aggregate_snapshot} and [rebuild] to a
    domain-pool-offloaded {!Trajectory.rebuild_tool_affinity_aggregate}.
    Exposed with injectable dependencies so tests can assert [rebuild] runs
    only on a missing/corrupt snapshot (no rescan when it is present). *)
