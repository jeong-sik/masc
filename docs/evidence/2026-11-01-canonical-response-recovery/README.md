# Canonical response authority survives terminal recovery

PR [#47059](https://github.com/jeong-sik/masc/pull/47059) records the admitted
response once before AfterTurn and checkpoint publication. Terminal recovery
uses that exact persisted response instead of admitting raw tool names against
the resumed agent's palette. Removing tools or adding exact raw names in
AfterTurn therefore cannot change the earlier normalization/filtering result.
Optional raw tracing precedes admission; absent tracing does not imply that
the journal retains the original wire blocks.

The public fresh fixture verifies the expected response id, stop, admitted
content and reported usage independently, then seals the actual AfterTurn
response, including completion telemetry, against output, OnStop and the
durable snapshot. Three synthetic recovery windows cover active provider,
provider-closed/turn-open, and provider-and-turn-closed boundaries. Cases also
cover tool removal and AfterTurn additions. Accepted terminal content creates
no effects or canonical tool observations, never redispatches the provider or
repeats AfterTurn, preserves usage/counter, and runs OnStop only when pending.
Malformed stops and existing inconsistent-frontier controls stay rejected.

Both actual executions are workflow **Test**, ref
`fix/terminal-resume-frontier-20261101`, `minimal=true`, exactly
`packages/agent_core/test/test_pipeline,packages/agent_core/test/test_execution_journal`,
using the existing 600-second targeted-suite guard:

- [41305104822](https://github.com/jeong-sik/masc/actions/runs/41305104822),
  checkout `8b33c1143c9551bc7cbf5624dfbd0566fb7bc836`: **FAILURE, 124 PASS / 19 FAIL**.
  Pipeline: 103 PASS / 19 FAIL; journal: 21 PASS.
- [41307303997](https://github.com/jeong-sik/masc/actions/runs/41307303997),
  checkout `b8a1523884e571a91b90971d8cb682442d4296f7`: **SUCCESS, 143 PASS / 0 FAIL**.
  Pipeline: 122 PASS; journal: 21 PASS.

The first fixture compared the transport mock's telemetry=None with the public
completion result, which adds Some telemetry. All 19 accepted terminal controls
failed at that fresh equality before durable/recovery assertions. The correction
captures the independently verified actual AfterTurn response and preserves
whole-record equality everywhere. Production lib/Core-lib/config trees are
byte-identical across these executions; the complete delta is the Pipeline
fixture and a README. This is a fixture correction, not a same-fixture product
before/after pair and not 19 product defects fixed.

`source-comparison.json` records separate fixture hashes and source-sealed key
digests for both executions. `cases.tsv` contains all 143 corresponding group/
index slots and each run's status; a slot alone is not an unchanged case identity.
The Pipeline source hash changed, while the journal source hash did not.
The corrected execution reaches every accepted recovery assertion, including
the six palette-change cases and two unregistered-only controls.

`manifest.json` preserves completed metadata, checkout, raw/selected byte counts
and SHA-256 digests. Both retained captures include every 143 actual case row,
target, checkout, summary and selected failure context. They are normalized
line-selected derivatives with independent digests. Raw jobs remain under
ignored `artifacts/issues-oldest-20261101/remote-core-drift/`.
`source-sha256.json` seals 19 inputs and four trees at successful b8; an evidence-only
publication must preserve them. Historical 135/0 in the earlier terminal-stop
bundle is separate and is never added to 143/0.

No local Dune build/typecheck ran. Recovery windows are reconstructed in one
process; OS restart, real provider/account, installed runtime, full regression,
whole-stack integration and deployment remain unverified. Internal review is
not formal non-author GitHub approval. #27890's full original acceptance remains
open and no issue is closed.
