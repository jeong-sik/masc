# Complete read-only queue observation for schedule drain evidence

Refs #26430. Base:3cce9a517b25863c00b48cfb3dd79b994ebc1044.

The schedule projection currently reads pending only, then the reaction ledger. A typed terminal transaction can have removed pending while its reaction projection is still outstanding. The existing private observer already compares two complete durable states without entering the owner transaction lock or checkpointing/compacting WAL. This layer publishes that same observation as observe_state_result with existing typed snapshot_read_error list. The pending-only observer projects its result through the same helper. No new read protocol, cache, writer, ACK policy, retry or budget is introduced.

## Defined execution

Only selected suite:test/test_keeper_reaction_ledger. A new scenario commits a real scheduled turn terminal through persistence. Inside actual after_commit (the owner lock is still held), the new observer reads the whole state. It compares all workspace file paths/bytes before and after, checks matching pending/outbox/actual receipt/exact source, and later identifies the same occurrence as completed with Terminal_evidence_pending. The reaction ledger still has only the dispatch row: the read does not invent an ACK. After explicit real projection, a later observation sees the outbox retired. Missing store is empty without creating files. Both pending and full-state observers share an actual between-samples generation-change case and must return typed incoherence instead of healthy state.

Three OCaml files parse; full diff whitespace and source hashes pass. No local Dune/typecheck or selected execution claimed. Independent source reviews, final head and requested minimal run must be recorded separately. Full regression unrun.

## Remaining required upper layer

This API is a prerequisite, not the #26430 fix by itself. The actual schedule page must consume coherent owner state before ledger reads, use exact/latest-incarnation/conflict and compact-source provenance semantics, retain ACK/cancel/transfer projection states without fabricated ledger booleans/timestamps, and handle retired exact receipts. Both detailed evidence and queue-drain UI must interpret the added closed states. Actual transaction-before-projection→page→TS tests must retain genuine dropped-stimulus misses and typed read failures. No operator outcome, browser/UI, installed runtime, performance, merge or whole-issue completion is claimed here. #26430 stays OPEN.
