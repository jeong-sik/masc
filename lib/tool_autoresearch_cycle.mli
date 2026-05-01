open Base

(** Tool_autoresearch_cycle — Core ratchet logic for the
    [masc_autoresearch_cycle] tool.

    Reachable from {!Tool_autoresearch.dispatch} via the
    autoresearch tool registry.  Drives one iteration of an
    active autoresearch loop:

    + Resolve [loop_id] from args.
    + Read-acquire the loop registry; verify the loop is in
      [Running] status and {!Autoresearch.should_continue}.
    + Mutate registry in a write-acquired transaction
      (one cycle's worth of state advance + persist).
    + Render the post-cycle state as a JSON envelope (loop_id,
      status, score deltas, best-cycle pointers, completion
      reason on terminal states).

    Internal: ~14 helpers stay private — \[clip] (UTF-8-safe
    truncation), \[resolve_loop_id], the JSON shape builders for
    each branch (running / completed / error), the
    [Autoresearch.with_loops_rw] / [with_loops_ro] transaction
    wrappers around the active-loops Hashtbl, score-extraction
    helpers, and the small score formatters.  All consumed only
    inside {!handle_cycle}'s pipeline. *)

val handle_cycle :
  Tool_autoresearch_context.t -> Yojson.Safe.t -> Yojson.Safe.t
(** [handle_cycle ctx args] runs one ratchet step on the loop
    identified by [args.loop_id]:

    - Returns [{ "error": "No autoresearch loop running" }] when
      [loop_id] is missing.
    - Returns [{ "error": "Loop <id> not found" }] when
      [loop_id] is not registered.
    - Returns [{ "error": "Loop is not running" }] when status
      is not [Running].
    - Returns [{ "loop_id"; "status": "completed"; "reason";
      "best_score"; "best_cycle" }] when
      {!Autoresearch.should_continue} is false at entry —
      completion reason is one of the values returned by
      {!Autoresearch.completion_reason}, defaulting to
      ["completed"].  The loop is finalised + persisted via
      {!Autoresearch.complete_if_finished}.
    - Otherwise advances the cycle, persists state via
      {!Autoresearch.save_state}, and returns the running-loop
      JSON envelope.

    All registry mutations happen under
    {!Autoresearch.with_loops_rw} so concurrent calls are
    serialized at the registry level. *)
