(** RFC-0199 Phase B — keeper-side probe adapter.

    Runs {!Deterministic_evidence_evaluator} against a claimed task's typed
    [task_contract.evidence_claims] using the keeper sandbox file system as
    the probe. This is the production consumer that gives the typed field a
    non-zero fan-in (the Phase A [required_evidence_typed] field was removed
    for fan-in 0; this re-introduction ships with a real consumer).

    v1 supports file-existence claims ([Artifact_exists] / [File_changed]);
    other claim kinds ([Tests_pass], [PR_merged], [CI_pass], [Custom_check])
    resolve to [None] -> [Indeterminate] (never auto-complete) until their
    probes (Shell-IR command runner, forge queries) are wired. *)

val all_satisfied :
     config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> Evidence_claim.t list
  -> bool
(** [true] iff the NON-EMPTY claim list evaluates to [Satisfied] under a probe
    backed by the keeper's sandbox-resolved file system. An empty list and any
    [Unknown]/[Indeterminate] claim yield [false] — Unknown is never
    permissive, so a task is auto-completed only when every declared claim is
    a definite, measured "yes". *)
