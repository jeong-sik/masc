
(** Tool_autoresearch_broadcast — SSE broadcast for autoresearch
    loop events.

    Both broadcasters serialise their event as a JSON object and
    push it via {!Sse.broadcast}. [Eio.Cancel.Cancelled] is
    re-raised so an ambient cancel propagates; any other
    exception during [Sse.broadcast] is logged at
    [Log.Autoresearch.warn] and swallowed so a downstream SSE
    failure cannot interrupt the autoresearch loop.

    {!Tool_autoresearch} re-exports both bindings via
    [include Tool_autoresearch_broadcast]; {!Tool_autoresearch_cycle}
    consumes them directly via [open Tool_autoresearch_broadcast]. *)

val broadcast_cycle_result :
  Autoresearch.loop_state ->
  Autoresearch.cycle_record ->
  unit
(** Broadcast a per-cycle SSE event with type
    ["autoresearch_cycle"] containing the cycle number,
    hypothesis, decision (via {!Autoresearch.decision_to_string}),
    score before/after, delta, baseline, and best score. *)

val broadcast_loop_lifecycle :
  string ->
  Autoresearch.loop_state ->
  unit
(** Broadcast a lifecycle SSE event with the caller-supplied
    [event_type] (e.g. ["autoresearch_started"] /
    ["autoresearch_stopped"]) and the loop state's id, status,
    current cycle, best score, and target file. *)
