(** The PayoutOwed step (RFC-goal-candle-ledger 3.2, step 2).

    When the operator confirms a Goal's passing result, the Goal owes a payout
    for that pass. The step writes that fact to the Candle ledger under the
    Goal's lock, after the confirmation record is saved and before the phase is.
    Reopen and drop take the same lock, so neither can come between the writes.
    The three writes are not atomic. RFC 3.2 lists what each failure leaves: a
    row that could not be written leaves a confirmation and no debt, and a phase
    that could not be saved leaves the row, which confirming again does not
    write twice. One case is not in that list: an append that fails and then
    fails to roll back too can leave a whole row in the file while the
    confirmation is refused, which is the state a phase that could not be saved
    leaves.

    The confirmed verifier run identifies its Snapshot. Two runs answering
    the same request within one second are distinct even when their
    [recorded_at] strings are equal.

    It writes nothing unless Candle is enabled. It also writes nothing when the
    pass has no [Snapshot], because Candle was not on when the Goal passed, and
    when the Goal already owes a payout ({!Candle_payout.owed_pass}). While
    Candle is enabled, a row that cannot be written refuses the confirmation.
    The operator confirms again, and the step gives the same answer the second
    time. *)

val record :
  now:(unit -> float)
  -> Workspace_utils_backend_setup.config
  -> Goal_store.goal
  -> Goal_verification.verdict
  -> Goal_verification.confirmation
  -> (unit, string) result
(** [now] gives the Unix time the row is stamped with. *)

val after_confirmation :
  Workspace_utils_backend_setup.config
  -> Goal_store.goal
  -> Goal_verification.verdict
  -> Goal_verification.confirmation
  -> (unit, string) result
(** {!record} with the wall clock, in the shape
    {!Workspace_goals.confirm_completion} takes. *)
