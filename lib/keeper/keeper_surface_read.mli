(** Keeper_surface_read — pull-based lane context (RFC-0223 P3).

    Pure projection behind the [keeper_surface_read] tool: filter the
    keeper's chat log to one connector lane and derive the lane's
    participant roster by folding over the rows. No store of its own —
    the chat log is the only source, so the roster ages out with log
    retention (RFC-0223 §5: log-bounded by design, no separate person
    store). Paging uses the chat store's physical cursor. *)

(** One person seen on the lane, derived from user lines carrying a
    [speaker_id] (RFC-0223 P1). Keeper/assistant lines are the
    keeper's own output and are never participants. *)
type participant = {
  id : string;
  name : string option;  (** Most recent non-empty name observed. *)
  authority : Keeper_chat_store.speaker_authority;
  first_seen : float;
  last_seen : float;
  message_count : int;
}

val default_limit : int
val normalize_limit : int -> int
(** Apply the existing local page limit before loading the store page. The
    limit bounds physical rows; a lane-filtered page can contain fewer rows. *)

(** Binding knowledge the runtime can prove (task-1596): the keeper's
    bound channel ids/names per connector lane. When [respond] receives
    it, labels the runtime can prove wrong are refused with the same
    error shape as [Keeper_surface_post] ([{"error": …}]) instead of a
    silent zero-row page: "slack"/"discord" when the keeper has no
    bound channels there (post's doctrine, mirrored on the read side),
    and any other non-core label absent from the loaded page's lane
    labels when that page is the whole history (no requested [cursor] and
    no [next_cursor]) — the refusal names the labels the page does carry.
    On any other page such a label reads as an empty page. Core
    lanes (dashboard/agent/broadcast/webhook) always pass; absent
    bindings keep the projection pure and unverified. *)
type connector_bindings = { slack : string list; discord : string list }

(** [respond] filters [page.history_messages] to
    rows whose typed [surface] ([Surface_ref.lane_label]) equals
    [surface] (trimmed, exact),
    returning a JSON object string: [{surface, messages, participants,
    lane_row_count, returned, has_more, next_cursor}].

    - [messages]: every matching row in [page], in append order, each with
      role/content/ts and speaker fields when present, plus a [source]
      response field holding the row's [Surface_ref.lane_label] — the
      same field vocabulary as the REST history endpoint.
    - [participants]: roster folded over all loaded lane rows, sorted by
      [last_seen] descending.
    - [next_cursor] is the store page's opaque cursor, or JSON null when
      the prefix is exhausted. [has_more] is derived from its presence.
      Pass it as the next call's [cursor], including after an empty lane
      page. Neither timestamps nor the filtered rows reconstruct a cursor.
    - Rows without a typed surface never match. A persisted surface that
      does not decode refuses the store page rather than being read as unscoped.
    - [cursor]: the cursor the page was loaded with; [None] for the
      newest page.
    - A blank [surface] is refused ([Error]), not read as a default lane.
    - With [~bindings] (task-1596) a provably wrong label is refused — see
      [connector_bindings].

    [Error] carries the refusal sentence. Every refusal is a label the
    caller named and can correct. *)
val respond :
  ?bindings:connector_bindings ->
  surface:string ->
  cursor:Keeper_chat_history_page.cursor option ->
  Keeper_chat_store.history_page ->
  (string, string) result
