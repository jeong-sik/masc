# Canonical publication report types, 2026-10-08

`Atomic_write` duplicated the reconciler's source state, prepared/bound outcomes
and report rows as four smaller `publication_recovery_*` variants. The mapper
threw away operation identities, observations and typed failures. Its only
consumer was `Publication_recovery_for_testing.report_row_kinds`, which forwarded
it to `test_fs_compat_publication_reconciliation`. No production reader consumed
the copied variants. A copied report alias and diagnostic forwarding path were
used only by that projection/consumer too.

Remove those variants, mappings, alias and forwarding APIs. The test reads
`Capability_recovery_reconciler.report_rows` and `report_to_string` directly.
It retains the same actual reconciliation entrypoint and all durable evidence,
owner admission, preserved source/stage/target, failure, permissions and privacy
assertions. Three single-row success/mismatch assertions additionally verify the
exact operation ID, which the copied projection had discarded. No diagnostic
string is parsed to select the typed result, and no substitute kind projection
is introduced in tests.

The four production/test-support source/interface files lose 291 lines.
`Atomic_write.ml` drops from 2,773 to 2,640 lines. Its publication effects,
mutation leases, staging cleanup, and remaining test-injection responsibilities
still require semantic review. The 2,000-line selection criterion is not a
completion target, and all initial 171 candidates remain in scope.

## Actual consumers and evidence

The removed contract was reachable only along this path:

`Atomic_write copied report API → Publication_recovery_for_testing → publication reconciliation assertions`.

The final path is:

`Publication_recovery_access.reconcile_owner → canonical report → reconciler.report_rows → assertions`.

The public `Fs_compat.Publication_recovery` surface, authoritative reconciler,
structured JSON/diagnostic projection, codecs, stored evidence, and recovery
mutation implementations are unchanged.

The operator authorized these narrow local checks:

| Changed contract | Direct verification target | Measured result |
| --- | --- | --- |
| Removed internal variants/projections and test-support exports | focused build of `test_fs_compat_publication_reconciliation.exe` | Exit 0; [build.log](build.log), empty successful output |
| Canonical row and diagnostic consumer | existing `recovery evidence preservation` group | 14 cases passed; [recovery.log](recovery.log) |

[checks.json](checks.json) records commands, terminal exit codes and base SHA.
The 14 cases cover prepared and bound recovery, root mismatch,
forensic record round-tripping, corrupt/invalid records, transition failure,
unavailable inventory, preserved lane residue, unchanged directory permissions,
and corrupt payload/privacy evidence. Skipped incremental inventory cases are
not counted. No new tests were added to mirror the deleted mapper.

Compilation does not certify the entire repository. Incremental inventory/race
scenarios, the full suite, live startup recovery, deployment and independent
GitHub approval remain unverified by this slice. The affected Godfile test is
marked partial: its evidence group was reviewed and executed, while its other
lifecycle/concurrency responsibilities remain pending.
