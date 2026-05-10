(** Keeper_passive_loop_detector — detect keepers stuck in no-progress loops.

    A "passive loop" occurs when a keeper completes N consecutive turns
    using only read-only / status tools without any execution or completion
    progress.  This is distinct from the stay-silent loop (which detects
    repeated [keeper_stay_silent] calls): here the keeper IS making tool
    calls but they are all passive reads that cannot satisfy an owned task
    contract.

    The same detector also tracks repeated required-tool contract failures
    where an actionable turn returns no keeper tool call. Those failed turns
    never reach the normal post-success progress classifier, so the keeper
    failure path records them explicitly here.

    @since #12799 *)

val progress_class_of_disposition :
  Keeper_turn_disposition.t -> string option
(** Map a typed [Keeper_turn_disposition.t] into a detector progress class.
    Returns [Some _] only for required-tool failure dispositions
    ([Required_tool_use_no_tool_call] and [Required_tool_use_unsatisfied])
    that should count toward an inter-turn no-progress loop; every other
    disposition variant returns [None]. *)

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
    - ["required_tool_no_call"] or ["required_tool_unsatisfied"] increments
      the required-tool failure streak.
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

val nudge_message : keeper_name:string -> string option
(** [nudge_message ~keeper_name] returns [Some message] when a passive loop
    has been detected for [keeper_name] (streak has reached the threshold and
    the detection latch is active), or [None] when no passive loop is active.

    The returned string is a directive intended for injection into the next
    turn's before_turn nudge, prompting the keeper to take an execution or
    completion action instead of continuing passive read-only behavior. *)

val reset : keeper_name:string -> unit
(** Reset all streak state for [keeper_name].  Used when a keeper is
    unregistered or restarted. *)

val reset_all_for_test : unit -> unit
(** Clear all per-keeper state.  Test-only helper. *)
