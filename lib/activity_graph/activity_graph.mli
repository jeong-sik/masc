(** Activity_graph — event log facade.

    Re-exports {!Activity_graph_types} and {!Activity_graph_registry}
    so callers can reach the full type / registry surface via
    [Activity_graph.X].
    Type identity is preserved end-to-end across the runtime
    via the [include module type of struct include M end] form
    (cycle 187 [workspace_utils.mli] rationale): the [event],
    [entity_ref], and [client] types reachable
    via {!Activity_graph} are the same nominal types as those
    reachable via the source modules.

    On top of the runtime, four locally-defined helpers
    persist event JSONL files under [Workspace_utils.masc_dir]
    and project the log into the JSON view consumed by the SSE
    activity stream and the dashboard events endpoint:

    - [format_sse_event_data] — private single-event SSE wire encoding.
    - {!emit} — append + fan-out to every registered SSE
      client.
    - {!list_events} — page over the persisted log.
    - {!json_response} — paginated JSON for the polling
      dashboard.

    Internal helpers stay private at this boundary
    ([root_dir], [month_dir], [day_path], [seq_path],
    [lock_path], [ensure_dirs], [read_current_seq],
    [write_current_seq], [append_line], [parse_event_line],
    [collect_event_files], [read_all_events],
    [matches_filters]). *)

include module type of struct
  include Activity_graph_types
end

include module type of struct
  include Activity_graph_registry
end

(** {1 SSE wire encoding} *)

(** The directory this store occupies under [.masc]. Readers of the same
    store name it from here instead of spelling the literal. *)
val store_dirname : string

val root_entry_is_metadata : string -> bool
(** Exact root-level bookkeeping names owned by this producer: the sequence
    counter and the physical lock file used by the local flock fallback.
    They are not dated event data. This classification applies only directly
    under this store root, not inside a month or another event store. *)

(** {1 Event emission} *)

val subscribe_written : (base_path:string -> unit) -> (unit -> unit)
(** Observe an event-store write attempt after its file lock is released,
    including a failure after a visible append or sequence update. Carries
    the raw workspace owner only. Callbacks must not block or yield, and
    cannot change the writer's result. The returned removal is idempotent. *)

val failed_write_notifications : unit -> int

val emit :
  Workspace_utils.config ->
  ?actor:entity_ref ->
  ?subject:entity_ref ->
  ?tags:string list ->
  kind:string ->
  payload:Yojson.Safe.t ->
  unit ->
  event
(** Persists a new event under
    [Workspace_utils.masc_dir config / "activity-events" / YYYY-MM / YYYY-MM-DD.jsonl]
    and pushes it to every matching registered SSE client.

    The file lock at {!Activity_graph_registry} scope is
    held while the [seq] counter is bumped and the JSONL
    line is appended, so concurrent emits serialize cleanly.
    Push failures are logged via [Log.Misc.warn] and the
    failing client id is unregistered — emission never
    raises on a single dead client. *)

(** {1 Read paths} *)

val list_events :
  Workspace_utils.config ->
  ?kinds:string list ->
  after_seq:int ->
  limit:int ->
  keep:(event -> bool) ->
  unit ->
  event list
(** Reads the persisted log, applies the [kinds] filter and
    [keep], and returns the page of events strictly after
    [after_seq] up to [limit] entries.  When [after_seq = 0]
    the page is the {b last} [limit] entries (newest-first
    dashboard initial load); otherwise it is the next [limit]
    forward (catch-up tail).

    [keep] runs before the page is cut, so [limit] counts
    events the caller asked for rather than events the log
    happened to hold. A caller that filters afterwards has no
    value of [limit] that means "this agent's newest N": the
    page fills with whatever the workspace was busy doing. *)

(** {1 JSON projections} *)

val json_response :
  Workspace_utils.config ->
  ?kinds:string list ->
  after_seq:int ->
  limit:int ->
  keep:(event -> bool) ->
  unit ->
  Yojson.Safe.t
(** Polling-friendly JSON envelope: [generated_at_iso],
    [dashboard_surface], [source], [retention], [query],
    [events], [count], [total_matching_events], [after_seq],
    [next_after_seq], [limit], [kinds], [latest_seq], and
    [latest_matching_seq].  [next_after_seq] is the seq of the
    last returned event so the caller can resume cleanly on the
    next poll.  [latest_seq] is the max of the persisted counter
    and JSONL rows so stale [_seq] files cannot make dashboard
    cursors move backward. [keep] applies before paging and exact totals. *)

val recent_json_response :
  Workspace_utils.config ->
  raw_limit:int ->
  keep:(event -> bool) ->
  unit ->
  Yojson.Safe.t
(** Bounded recent-candidate projection for the default events query. Read the
    newest [raw_limit] raw rows, then apply [keep] before returning them. The
    response reports [coverage="recent_window"] and [raw_window_limit]; this
    does not promise the newest [raw_limit] authorized rows across all history.
    [total_matching_events] and [latest_matching_seq] are JSON null because
    older rows were not checked. Explicit {!json_response} queries retain
    exact full-history filtered totals and report [coverage="full_history"]. *)

type cache_stats = {
  past_day_files : int;  (** parsed day files held *)
  past_day_records : int;  (** events across them *)
}

val cache_stats : unit -> cache_stats
(** What the past-day parse cache is holding right now.

    Exists because sizing it from outside the process meant taking RSS,
    reading [live_words] off /health, and multiplying the on-disk JSONL by a
    guessed parse factor -- an estimate good to within a factor of two, which
    settles nothing. [past_day_records] is the number a retention change
    moves.

    A read rather than a gauge: this module has no metric dependency, and the
    caller that already exports gauges decides how often to look. *)

module For_testing : sig
  val reset_current_day_cache_for_testing : unit -> unit
  (** Clears the workspace-owned parse and aggregate caches. *)

  val reset_past_day_cache_for_testing : unit -> unit
  (** Clears the per-path, full-fingerprint event-list past-day cache. *)

  val reset_line_count_cache_for_testing : unit -> unit
  (** Clears the per-file line-count cache that answers [total] without
      parsing. *)

  val current_day_rebuild_count : unit -> int

  val current_day_append_count : unit -> int
  (** How often the current-day file was read from where the last read
      stopped rather than from zero. A test that appends to a file and reads
      it again asserts on this: the events being right does not say which
      path produced them. *)

  val all_events_rebuild_count : unit -> int
  (** Number of full retained-list aggregate rebuilds since the current-day
      cache was reset.  Repeated unchanged projections must reuse one build. *)

  val past_merged_rebuild_count : unit -> int
  (** Number of past-day merge rebuilds. An append to the current day misses
      the aggregate but must not move this: the past files did not change,
      and re-sorting them is the cost the split exists to avoid. *)

  val touch_workspace_cache : string -> unit
  val workspace_cache_count : unit -> int
  val workspace_cache_mem : string -> bool

  val past_day_cache_entry_count : unit -> int

  val current_day_path : Workspace_utils.config -> string
  (** Path of the file [read_all_events] treats as "current day" for
      [config]. Exposed so tests can write directly to it to simulate
      append growth, truncation, or invalid UTF-8 without going through
      {!emit}. *)
end

val heap_root : (Obj.t -> 'a) -> 'a
(** Run [walk] on this module's retained state, under the lock that guards
    it, for [Heap_roots.measure] to size with [Obj.reachable_words].
    Diagnostics only: the walk stalls the process for its duration. *)
