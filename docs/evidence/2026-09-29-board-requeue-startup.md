# Authorized Board retry stopped at process startup

Observed against server commit `c183bd896cdc4b7ad4b3a2addd4865ef643220cd`.
At 2026-09-28 23:34:12 UTC, the system log reported:

```text
board attention worker stopped keeper=e-masc-the-leader:
Board attention worker fatal stage=process_start_recovery
detail=Ready partition is not the quarantined generation successor:
ba-root-d32a33dad1d9fbfff64205852ce74fce37c4279596030c3f17ad6cbc213f8d7f
(lane continues)
```

The persisted partition snapshot was Ready at generation 9. Its candidate
`ef87b980d7ede0ccdcee0b4b14cb033cdf9c6c2ac0e29d9bd50749c16a7306f0`
retained a Requeued quarantine for generation 5, with `requested_by=masc-tui`
and `requeued_at=1790602049.010778`. The original failure category was
`exact_lane_exhausted`. Twelve Keeper Board workers reported the same error
after this server start; ordinary Keeper turns could still run.

The observed snapshot alone does not reconstruct the intervening transitions.
The source permits an authorized requeue to advance through Ready, Running,
bound execution, and a deferred Ready. Process-start recovery also moves
Running to Ready. Both legal paths advance beyond the immediate successor
of the retained quarantine generation, which the old reconciliation rejected.

The change recognizes a later Ready only when its candidate retains completed
requeue authorization for the same partition. The partition loader still
validates identities and transition generations. `confirm_ready` retains
snapshot comparison and durability confirmation. Quarantined and merely
requested candidates remain refused; manual command conflict convergence is
unchanged.

The existing manual requeue lifecycle scenario now covers a spent lane,
process-start reconciliation twice, another interrupted Running attempt,
and eventual judgment and owner settlement. Existing premature authorization
and stale quarantine rejection scenarios remain in place.

Local validation: `git diff --check`. No local build was run, per the repository
execution protocol. The new regression scenario requires CI execution. This
source change is not evidence that the running server's Board workers recovered.
