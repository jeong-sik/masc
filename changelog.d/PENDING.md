### Fixed

- A keepalive cycle that ran no turn no longer reports a turn status. The
  loop chose between `turn_succeeded` and `turn_failed` from the stored
  failure streak, so after a server restart a Keeper that had inherited a
  nonzero streak went to `failing` within a second of `fiber_started`, before
  it ran a turn, and rosters showed it offline while its turn was running.
  The cycle status now says whether a turn ran and how it ended; the streak
  only fills `consecutive`. Cycles inside the warmup, cycles with nothing
  scheduled, cycles the phase gate skipped or cancelled, and Owner
  rejections dispatch neither event. A Keeper now leaves `failing` when a
  turn of its own succeeds or its fiber restarts; clearing the streak alone
  no longer changes the phase (#34673) (#PENDING).
