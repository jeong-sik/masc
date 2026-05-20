(** RFC-0145 PR-4-1: extract post-turn deterministic memory write
    from [keeper_agent_run.run_turn] Step 8 body (L1518-L1568).

    Appends keeper memory notes from the reply (deterministic path),
    optionally augmented by tool-emission-hook accumulator results
    when [Keeper_tool_emission_hook.masc_tool_emission_enabled]
    returns true.  Logs aggregated counts via
    [Keeper_turn_telemetry.log_keeper_memory_write] when any notes
    were written.

    See RFC #3646 Section 3 for the Det/NonDet boundary background.

    Side effects only.  Exceptions are caught (counter +
    error log); [Eio.Cancel.Cancelled] is *not* explicitly
    re-raised in the original block, matching the pre-Cycle 5
    deterministic-memory path behavior.  No-op when no notes are
    written. *)
val write_post_turn
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> state_snapshot:Keeper_state_snapshot.t
  -> turn:int
  -> reply:string
  -> unit
