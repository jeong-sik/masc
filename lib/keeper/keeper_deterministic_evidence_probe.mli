(** RFC-0199 Phase B — keeper-side probe adapter.

    Runs {!Deterministic_evidence_evaluator} against a claimed task's typed
    [task_contract.evidence_claims] using the keeper sandbox file system as
    the probe. This is the production consumer that gives the typed field a
    non-zero fan-in (the Phase A [required_evidence_typed] field was removed
    for fan-in 0; this re-introduction ships with a real consumer).

    v1 supports file-existence claims ([Artifact_exists] / [File_changed])
    and Shell-IR command claims ([Tests_pass]). Docker command claims require
    the caller's turn-scoped sandbox factory; without one they resolve to
    [None] -> [Indeterminate] rather than silently falling back to the host.
    Other claim kinds ([PR_merged], [CI_pass], [Custom_check]) still resolve to
    [None] -> [Indeterminate] until their probes are wired. *)

val evaluate :
     ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> Evidence_claim.t list
  -> Deterministic_evidence_evaluator.outcome
(** Evaluate typed evidence claims and preserve the concrete
    [Satisfied]/[Unsatisfied]/[Indeterminate] reason. *)

val all_satisfied :
     ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> Evidence_claim.t list
  -> bool
(** [true] iff the NON-EMPTY claim list evaluates to [Satisfied] under a probe
    backed by the keeper's sandbox-resolved file system. An empty list and any
    [Unknown]/[Indeterminate] claim yield [false] — Unknown is never
    permissive, so a task is auto-completed only when every declared claim is
    a definite, measured "yes". *)
