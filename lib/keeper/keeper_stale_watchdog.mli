(** Stale-turn watchdog — standalone fiber for keeper liveness detection.

    @since PR #10670 — extracted from Keeper_supervisor. *)

open Keeper_types

(** Fork a stale-turn watchdog fiber for the given keeper.

    Two detection modes:
    - Idle stall: [last_turn_ts] older than 300s while [Running].
    - Failure loop: [consecutive_noop_count >= 3] — catches keepers in
      LLM timeout loops where [last_turn_ts] stays fresh.

    On detection, sets [fiber_stop] and emits a stale broadcast. The
    supervisor's [sweep_and_recover] picks up the stopped fiber and
    restarts with exponential backoff. *)
val fork_stale_watchdog
  :  'a context
  -> keeper_meta
  -> Keeper_registry.registry_entry
  -> unit
