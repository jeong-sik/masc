(** Briefing session [last_event] provenance marker.

    {!Briefing_compactors.compact_session_json} synthesises the
    [last_event] JSON object whether or not the input
    [recent_events] list was empty.  Downstream consumers (dashboard,
    operator handoff, debug dumps) cannot otherwise distinguish a
    real "this is the most recent observed event" payload from a
    placeholder "no events present, here is a sentinel".

    This typed variant is the closed enumeration of those two
    provenance paths, serialised into the [last_event.source] field
    so consumers can branch on it without re-running discovery.

    @since RFC-0058 follow-up / V14 audit (.tmp/memory-compacting-analysis.html) *)

type t =
  | Recent_event_latest
      (** [recent_events] was non-empty; [last_event] mirrors the final
          element.  Real data — caller may trust [event_type], [actor],
          [ts_iso] as observed. *)
  | Fabricated_no_recent_events
      (** [recent_events] was empty.  [last_event] is a sentinel record
          with [event_type="none"], [ts_iso="unknown"], [actor="unknown"],
          [task_title="no recent session events"].  Caller must NOT
          treat the fabricated fields as observations. *)

val to_label : t -> string
(** Lowercase JSON-string label used in [last_event.source].
    Stable across releases — downstream filters depend on these
    exact strings. *)
