(** Keeper_passive_loop_detector — detect keepers stuck in passive-read loops.

    A "passive loop" occurs when a keeper completes N consecutive turns
    using only read-only / status tools without any execution or completion
    progress.  This is distinct from the stay-silent loop (which detects
    repeated [keeper_stay_silent] calls): here the keeper IS making tool
    calls but they are all passive reads that cannot satisfy an owned task
    contract.

    @since #12799 *)

val record_turn :
  keeper_name:string ->
  progress_class:string ->
  unit
(** [record_turn ~keeper_name ~progress_class] updates the passive loop
    streak for [keeper_name].

    [progress_class] is the string representation of the
    [Keeper_tool_disclosure.tool_progress_class] for the turn's dominant
    tool usage:
    - ["passive_status"] or ["claim_context"] increments the streak.
    - Any other value (["execution"] / ["completion"]) resets the streak
      and clears the detection latch.

    When the streak reaches the threshold (default 5, env
    [MASC_KEEPER_PASSIVE_LOOP_THRESHOLD]), a Prometheus counter is
    incremented and a structured WARN log is emitted.  The counter is
    latched per episode — it will not fire again until the streak resets
    and a new episode begins. *)

val current_streak : keeper_name:string -> int
(** Return the current passive-only streak for [keeper_name].
    Returns 0 if the keeper has no recorded state. *)

val reset : keeper_name:string -> unit
(** Reset all streak state for [keeper_name].  Used when a keeper is
    unregistered or restarted. *)

val reset_all_for_test : unit -> unit
(** Clear all per-keeper state.  Test-only helper. *)
