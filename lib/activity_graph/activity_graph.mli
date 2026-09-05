(** Activity_graph — event log + live-graph projection facade.

    Re-exports {!Activity_graph_types}, {!Activity_graph_registry},
    and {!Activity_graph_reducer} so callers can reach the full
    type / registry / reducer surface via [Activity_graph.X].
    Type identity is preserved end-to-end across the runtime
    via the [include module type of struct include M end] form
    (cycle 187 [workspace_utils.mli] rationale): the [event],
    [entity_ref], [client], and [agent_span] types reachable
    via {!Activity_graph} are the same nominal types as those
    reachable via the source modules.

    On top of the runtime, six locally-defined helpers
    persist event JSONL files under [Workspace_utils.masc_dir]
    and project the log into JSON views consumed by the SSE
    activity stream and the dashboard graph endpoint:

    - [format_sse_event_data] — private single-event SSE wire encoding.
    - {!emit} — append + fan-out to every registered SSE
      client.
    - {!list_events} — page over the persisted log.
    - {!json_response} — paginated JSON for the polling
      dashboard.
    - {!graph_json} — folded graph (nodes / edges / kind
      counts / 7×24 heatmap) used by the live view.
    - {!agent_spans_json} — derived agent-span timeline
      reconstructed from start / end event pairs.

    Internal helpers stay private at this boundary
    ([root_dir], [month_dir], [day_path], [seq_path],
    [lock_path], [ensure_dirs], [read_current_seq],
    [write_current_seq], [append_line], [parse_event_line],
    [collect_event_files], [read_all_events],
    [matches_filters], [list_events_with_total],
    [window_meta], [span_start_kind],
    [span_end_classification], [StringMap]). *)

include module type of struct
  include Activity_graph_types
end

include module type of struct
  include Activity_graph_registry
end

include module type of struct
  include Activity_graph_reducer
end

(** {1 SSE wire encoding} *)

(** The directory this store occupies under [.masc]. Readers of the same
    store name it from here instead of spelling the literal. *)
val store_dirname : string

(** {1 Event emission} *)

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
    cursors move backward. *)

val graph_json :
  Workspace_utils.config ->
  ?kinds:string list ->
  ?limit:int ->
  ?timeline_limit:int ->
  ?since_ms:int ->
  unit ->
  Yojson.Safe.t
(** Live-graph projection.  Folds the filtered event slice
    (default [limit = 500]) through {!reduce_event}, then
    emits an [`Assoc] with [nodes], [edges], [kind_counts]
    (sorted), a 7×24 [heatmap], a recent-event timeline
    capped at [timeline_limit] (default 80), and a [window]
    metadata record (limit / events_shown / events_store_total
    / has_more). *)

val agent_spans_json :
  Workspace_utils.config ->
  ?limit:int ->
  ?since_ms:int ->
  unit ->
  Yojson.Safe.t
(** Reconstructs agent-span timelines from the event log by
    pairing span-start kinds with their classified span-end
    kinds.  Open spans (start without matching end in the
    window) are reported with [Span_open] and [end_ms] set
    to "now".  Returns [`Assoc [agents; spans; time_range;
    window]]. *)

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

  val reset_line_count_cache_for_testing : unit -> unit
  (** Clears the per-file line-count cache that answers [total] without
      parsing. *)
  (** Clears the per-path, full-fingerprint event-list past-day cache. *)

  val current_day_rebuild_count : unit -> int

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

val heap_root : unit -> Obj.t
(** The retained state of this module as an opaque value for
    [Heap_roots.measure] to walk with [Obj.reachable_words]. Diagnostics
    only: the walk stalls the process for its duration. *)
