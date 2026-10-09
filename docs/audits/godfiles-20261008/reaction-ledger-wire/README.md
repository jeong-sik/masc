# Reaction ledger current-row wire ownership, 2026-10-09

Parent: `3bca54d25f1f04c47623408888f87cf54995b718` (#42036).
Issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

`Keeper_reaction_ledger` mixed strict current-row validation with durable writes,
queue outbox recovery, incremental evidence caches and operator projections.
The Dune-private `Keeper_reaction_ledger_wire` now owns canonical closed kinds,
schema/storage generation, deterministic event identity, decoded current rows
and typed quarantine. It performs no filesystem, clock, observer or outbox effects.
Both exact evidence and operator summaries consume its one strict decoder.

These kinds carry product semantics: stimulus, turn start, turn finish, ACK and
cancellation are distinct evidence. They remain closed variants, and unknown or
inconsistent rows remain quarantine. This unit removes no wire fields and adds
no compatibility reader, new schema, public decoder or forwarding test API.
The public ledger `.mli` is byte-identical, including its abstract quarantine
reason and existing closed public variants.

The root retains clock acquisition, writer JSON construction, append/observer
ordering, schedule occurrence receipts, authoritative queue outbox read and
retirement, cache invalidation and operator projection. The extracted bodies
are byte-identical. Retained root bodies differ only in one explicit
`transition_source` parameter annotation, needed because the extracted metadata
record's labels now enter scope earlier. Root size changes from 2,171 to 1,646
lines; the private wire owner is 530 lines with a 119-line interface. Falling
below 2,000 lines does not finish the remaining responsibility audit.

## Consumer checks

| Boundary | Executed evidence | Result |
| --- | --- | --- |
| Writers → decoder → exact evidence and operator summaries | Existing isolated ledger suite: current writer shape, unknown kind/schema quarantine, keeper-local evidence, malformed/missing identity, duplicates, append observer order, prune/replacement/read-fault invalidation and fleet projection | 31 cases passed |
| Queue SSOT → ledger ACK projection → restart evidence | Existing persistence cases 9–10: completed-turn ACK and consecutive owner terminals without a projection gap | 2 cases passed |

Both focused executables compiled. Other queue cases were skipped by selection;
this is not a whole queue-suite result. [checks.json](checks.json) records terminal
commands and executable hashes; [source-sha256.json](source-sha256.json) records
11 source/context inputs. [extraction-comparison.json](extraction-comparison.json)
records body/public-interface equivalence. No tests were added to mirror the
implementation or extraction layout.

The first compile failed on record-label inference. Its terminal receipt, log
and inputs are retained separately in [initial-checks.json](initial-checks.json)
and [initial-source-sha256.json](initial-source-sha256.json). The focused compile
and all 33 executed cases succeeded after the annotation repair.

## Scope

These checks use isolated real files and in-process fixtures. Provider execution,
live Keeper continuity, visible UI, installation, deployment, full CI and whole
stack approval remain unverified. Storage, caches and summary responsibilities
remain pending in the original 171-candidate campaign.
