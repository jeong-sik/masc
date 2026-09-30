(** The Snapshot step (RFC-goal-candle-ledger 3.2, step 1).

    When the verifier's passing result is about to reach the verification
    ledger, the Goal's inputs to a later payout are written to the Candle ledger
    first: the request and exact verifier run that passed, the criterion revision, when it passed, when
    the Goal was created, its due date as the Goal held it, its title, metric
    and target, and the Tasks linked to it. A payout follows these values and
    not the Goal, so editing the Goal afterwards changes nothing.

    The step runs under the Goal lock, as the [before_proof_commit] step of
    {!Workspace_goals.commit_verifier_decision}. Without a [candle.toml], or
    while Candle is disabled, it writes nothing and lets the transition
    through. While Candle is enabled, a Snapshot that cannot be written refuses
    the transition: the verifier keeps the request pending, so nothing that a
    later payout needs is lost. *)

val record :
  now:(unit -> float)
  -> Workspace_utils_backend_setup.config
  -> Goal_store.goal
  -> Goal_verification.verdict
  -> (unit, string) result
(** [now] gives the Unix time the row is stamped with. *)

val before_proof_commit :
  Workspace_utils_backend_setup.config
  -> Goal_store.goal
  -> Goal_verification.verdict
  -> (unit, string) result
(** {!record} with the wall clock, in the shape
    {!Workspace_goals.commit_verifier_decision} takes. *)
