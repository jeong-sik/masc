# Board Ready confirmation evidence (task-1827)

`confirm_ready` now writes one cursor-fenced JSONL row containing both the unchanged Ready partition and a `ready_confirmation` observation. The observation records `confirmed_at` from the append boundary and `runtime_instance_id` from the server process. An incomplete final row is discarded by the existing process-start torn-tail recovery; a complete row contains both state and observation. Process-start compaction retains the observations as separate JSONL records while compacting partition states.

The partition test exercises Blocked → requeue → Ready confirmation, a repeated confirmation of the same generation after process-start recovery, deferral to a later Ready generation, another process-start recovery, and final settlement. It checks that the two same-generation observations and the later-generation observation remain in the ledger after compaction, and that the final partition is Settled. The simulated restarts run in one test process, so all events carry that process's boot identity; a distinct-boot runtime check remains necessary before calling per-boot behavior proven.

The original 12 affected rows have no confirmation time or boot identity. This change does not backfill them or assign them to earlier restarts. The 68 newly quarantined candidates in the 2026-09-29 A1 observation had no authorized requeue as of 03:04:37Z, so they provide no live Ready confirmation proof yet.

Validation: `ocamlformat --check` and `git diff --check` pass. Local Dune builds are disallowed by `docs/constitution.xml`; PR CI and an isolated distinct-boot replay are pending.
