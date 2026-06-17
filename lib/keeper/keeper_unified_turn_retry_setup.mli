(** RFC-0136 PR-4-a: outer setup record for [keeper_unified_turn] retry loop.

    Groups the wall-clock / budget / profile bindings that the retry loop and
    [do_run] closure both observe. *)

type retry_setup =
  { timeout_sec : float
  ; turn_started_at : float
  ; turn_deadline : float
  ; remaining_turn_budget_s : unit -> float
  ; elapsed_ms : float -> int
  ; current_turn_phase_elapsed_ms : float option -> int * int option
  ; keeper_profile : Keeper_types_profile.keeper_profile_defaults
  ; max_idle_turns : int
  ; max_turns : int
  }

(** [build ~now ~keeper_name ~channel ~turn_affordances] computes the wall
    clock and max-turn values that bound a turn attempt.

    [now ()] returns the monotonic clock time (in seconds) supplied by the
    Eio clock at the dispatch site.  The retry loop reads it repeatedly via
    [remaining_turn_budget_s] and [current_turn_phase_elapsed_ms].

    [channel] selects between reactive and scheduled-autonomous turn caps. *)
val build
  :  now:(unit -> float)
  -> keeper_name:string
  -> channel:Keeper_world_observation.keeper_cycle_channel
  -> turn_affordances:string list
  -> retry_setup
