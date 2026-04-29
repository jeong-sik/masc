(** Activity_graph — event log + live-graph projection facade.

    Re-exports {!Activity_graph_types}, {!Activity_graph_registry},
    and {!Activity_graph_reducer} so callers can reach the full
    type / registry / reducer surface via [Activity_graph.X].
    Type identity is preserved end-to-end across the cascade
    via the [include module type of struct include M end] form
    (cycle 187 [coord_utils.mli] rationale): the [event],
    [entity_ref], [client], and [agent_span] types reachable
    via {!Activity_graph} are the same nominal types as those
    reachable via the source modules.

    On top of the cascade, six locally-defined helpers
    persist event JSONL files under [Coord_utils.masc_dir]
    and project the log into JSON views consumed by the SSE
    activity stream and the dashboard graph endpoint:

    - {!format_sse_event} — single-event SSE wire encoding.
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
    [window_meta], [latest_seq], [span_start_kind],
    [span_end_classification], [span_end_kind],
    [span_end_status], [StringMap]). *)

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

val format_sse_event : event -> string
(** Renders [value] as a single SSE frame:
    [id: <seq>\nevent: activity\ndata: <json>\n\n].
    Consumed by {!emit} during fan-out and by the dashboard's
    catch-up endpoint when streaming the post-resume tail. *)

(** {1 Event emission} *)

val emit :
  Coord_utils.config ->
  ?actor:entity_ref ->
  ?subject:entity_ref ->
  ?tags:string list ->
  kind:string ->
  payload:Yojson.Safe.t ->
  unit ->
  event
(** Persists a new event under
    [Coord_utils.masc_dir config / "activity-events" / YYYY-MM / YYYY-MM-DD.jsonl]
    and pushes it to every matching registered SSE client.

    The file lock at {!Activity_graph_registry} scope is
    held while the [seq] counter is bumped and the JSONL
    line is appended, so concurrent emits serialize cleanly.
    Push failures are logged via [Log.Misc.warn] and the
    failing client id is unregistered — emission never
    raises on a single dead client. *)

(** {1 Read paths} *)

val list_events :
  Coord_utils.config ->
  ?kinds:string list ->
  after_seq:int ->
  limit:int ->
  unit ->
  event list
(** Reads the persisted log, applies the [kinds] filter, and
    returns the page of events strictly after [after_seq] up
    to [limit] entries.  When [after_seq = 0] the page is
    the {b last} [limit] entries (newest-first dashboard
    initial load); otherwise it is the next [limit] forward
    (catch-up tail). *)

(** {1 JSON projections} *)

val json_response :
  Coord_utils.config ->
  ?kinds:string list ->
  after_seq:int ->
  limit:int ->
  unit ->
  Yojson.Safe.t
(** Polling-friendly JSON envelope: [events], [count],
    [after_seq], [next_after_seq], [limit], [room_id]
    (kept as ["default"] for backward-compat), [kinds],
    [latest_seq].  [next_after_seq] is the seq of the last
    returned event so the caller can resume cleanly on the
    next poll. *)

val graph_json :
  Coord_utils.config ->
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
  Coord_utils.config ->
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
