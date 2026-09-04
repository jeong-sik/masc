(** RFC-0412 stage 2: replay a journaled keeper chat turn through the AG-UI
    projection for a reconnecting SSE client. *)

val replay :
  redact_text:(string -> string) ->
  redact_json:(Yojson.Safe.t -> Yojson.Safe.t) ->
  since_seq:int ->
  Keeper_chat_event_log.journaled_event list ->
  (int * Ag_ui.event) list
(** [replay ~since_seq entries] folds every entry from
    {!Server_keeper_chat_agui_projection.initial} and returns the projected
    events of the entries whose [seq] is strictly greater than [since_seq],
    each paired with that seq. The fold always starts at the beginning
    because projection state is cumulative: a text delta after the cut
    carries the message and run identity established before it. Entries
    that project to [None] (connector-only blocks) leave gaps in the returned
    seqs, so [since_seq] is a journal position, not a frame count. Each
    entry's own [ts] feeds the projection; the bus stamped that ts once and
    the live adapter projected with the same value
    ({!Keeper_chat_events.published}), so the output is byte-identical to the
    frames the live adapter wrote under the same redaction. The caller passes
    the redaction it has now: a secret registered for the keeper after the
    turn is redacted here and was not on the live wire. *)
