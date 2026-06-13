(** Keeper_surface_read — pull-based lane context (RFC-0223 P3).

    Pure projection behind the [keeper_surface_read] tool: filter the
    keeper's chat log to one connector lane and derive the lane's
    participant roster by folding over the rows. No store of its own —
    the chat log is the only source, so the roster ages out with log
    retention (RFC-0223 §5: log-bounded by design, no separate person
    store, no cursors). *)

(** One person seen on the lane, derived from user lines carrying a
    [speaker_id] (RFC-0223 P1). Keeper/assistant lines are the
    keeper's own output and are never participants. *)
type participant = {
  id : string;
  name : string option;  (** Most recent non-empty name observed. *)
  authority : Keeper_chat_store.speaker_authority;
  first_seen : float option;
  last_seen : float option;
  message_count : int;
  note : string option;
      (** Keeper-authored person note (RFC-0229), latest non-blank. *)
}

val default_limit : int
val max_limit : int

(** [respond ~surface ~limit ~has_more messages] filters [messages] to
    rows whose [source] label equals [surface] (trimmed, exact),
    returning a JSON object string: [{surface, messages, participants,
    lane_row_count, returned, has_more, oldest_ts?}].

    - [messages]: the last [limit] lane rows (chronological), each with
      role/content/ts/source and speaker fields when present — the
      same field vocabulary as the REST history endpoint.
    - [participants]: roster folded over ALL loaded lane rows (not just
      the returned slice), sorted by [last_seen] descending.
    - [has_more] / [oldest_ts] (RFC-0228 P1): [oldest_ts] is the oldest
      stamp across the whole loaded page — not just the lane — so
      passing it as the next call's [before] always makes progress,
      even through pages with no rows for this lane. Omitted when the
      page carries no stamped rows.
    - Rows without a [source] label (written before source labelling)
      never match; the description of the tool says so.
    - Blank [surface] is an error JSON, not a default lane. *)
val respond :
  surface:string ->
  limit:int ->
  has_more:bool ->
  notes:(string * string) list ->
  Keeper_chat_store.chat_message list ->
  string
(** [notes] (RFC-0229 P1) are keeper-scoped (not lane-scoped): they
    annotate matching roster entries, and a noted speaker absent from
    the loaded rows still appears as a note-only participant (zero
    [message_count], no sightings) — deliberate memory outliving the
    log window. *)
