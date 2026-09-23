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

(** Binding knowledge the runtime can prove (task-1596): the keeper's
    bound channel ids/names per connector lane. When [respond] receives
    it, labels the runtime can prove wrong are refused with the same
    error shape as [Keeper_surface_post] ([{"error": …}]) instead of a
    silent zero-row page: "slack"/"discord" when the keeper has no
    bound channels there (post's doctrine, mirrored on the read side),
    and any other non-core label absent from the loaded page's lane
    labels when that page is the whole history (no [before] cursor and
    no [has_more]) — the refusal names the labels the page does carry.
    On any other page such a label reads as an empty page. Core
    lanes (dashboard/agent/broadcast/webhook) always pass; absent
    bindings keep the projection pure and unverified. *)
type connector_bindings = { slack : string list; discord : string list }

(** [respond] filters [messages] to
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
    - [before]: the cursor the page was loaded with; [None] for the
      newest page.
    - Blank [surface] is an error JSON, not a default lane.
    - With [~bindings] (task-1596) a provably wrong label is refused
      with [{"error": …}] — see [connector_bindings]. *)
val respond :
  ?bindings:connector_bindings ->
  surface:string ->
  limit:int ->
  before:float option ->
  has_more:bool ->
  notes:(string * string) list ->
  Keeper_chat_store.chat_message list ->
  string
(** [notes] (RFC-0229 P1) are keeper-scoped (not lane-scoped): they
    annotate matching roster entries, and a noted speaker absent from
    the loaded rows still appears as a note-only participant (zero
    [message_count], no sightings) — deliberate memory outliving the
    log window. *)
