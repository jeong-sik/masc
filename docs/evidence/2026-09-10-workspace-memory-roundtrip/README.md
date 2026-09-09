# Workspace memory HTTP roundtrip

The verification harness takes a caller-supplied proposal and expected binary
commit. It checks server identity, publishes the proposal, reads it independently,
repeats publication and checks the inventory contains exactly one identical row.
It records failures without claiming that an attempted write did not happen.

Candidate CI build: 34397389273, source
`c08357ea1f78f1a04564cc96dbd2f38eb8c4e857`.

The initial probe against the older isolated d8d27990 runtime rejected the source
mismatch before POST (`source-mismatch.json`, write_attempted=false). This only
verifies wrong-binary refusal. Successful storage/readback, persistence after
restart and actual Keeper reuse have not yet been demonstrated here.

```sh
python3 scripts/verify-workspace-memory-roundtrip.py \
  --base-url http://127.0.0.1:18935 --token-file /path/to/token \
  --proposal /path/to/proposal.json --expected-commit SOURCE_COMMIT \
  --output /path/to/fresh-evidence-directory
```

No local build was run. The script writes its output privately and does not copy
private memory inputs to Git automatically.

Review repair records each HTTP response before interpretation, including the
second POST and inventory GET. Literal credential echoes are withheld before
JSON decoding or persistence. A flushed, atomically replaced write-intent
receipt precedes each POST, so interruption cannot leave a false no-write claim.
Readback comparison uses canonical JSON (boolean and numeric values remain
distinct). Health evidence includes effective base path and MASC root.

The repaired mismatch probe (`source-mismatch-repaired.json`) again refused the
older isolated binary before any POST and retained both effective paths. Python
syntax and boolean-versus-number comparison checks passed. Successful runtime
roundtrip and restart/reuse evidence remain pending.

## Successful isolated HTTP roundtrip

The CI runtime-probe artifact 10122236589 was downloaded from run 34397389273.
All three executable hashes matched its manifest; the server's build-commit and
HTTP health both identified `c08357ea1f78f1a04564cc96dbd2f38eb8c4e857`.
The manifest explicitly says release_validated=false; this is an isolated probe,
not release or deployment validation.

On a newly initialized isolated base at port 18936, the saved public Qwen fixture
passed independent readback, repeated-publication ID equality and exactly-one
matching inventory row. `success/` retains every checked destination JSON and
the receipt, including effective runtime paths. No private Keeper corpus or
authentication token is included.

Persistence after restart, actual Keeper retrieval and semantic verification
remain unmeasured. The production server was not replaced.

## Process restart persistence

The isolated listener was identified by PID and exact command, then terminated
with SIGTERM; its execution handle exited with code zero. The same binary and
base path were started again. Before any further POST, GET by the previous ID
returned canonical JSON identical to the pre-restart readback. The runtime
instance ID changed while source commit and effective paths stayed the same.
`success/restart-readback.json` records those identities and returned proposal.
This proves persistence across this graceful process restart; it does not prove
crash/power-loss durability or actual Keeper use.

## Actual Keeper list retrieval

A separate on-demand Keeper in the isolated runtime invoked
`keeper_workspace_memory_read` with `{}` and completed operation
`kmsg-6b7057abb90a24d2561b8d95f6e87fa3`. The tool-call record reports success
and the saved proposal. Its answer preserves the report-format conflict, the
12-to-21-second correction, proposal ID and source IDs s1–s4, while stating that
semantic verification was not performed. `keeper-reuse/` contains the operation,
selected tool receipt and answer.

The answer also overinterprets missing source_bound stores as inability to read
original text. The full proposal still contains ordinary-source facts; a follow-up
asks the Keeper to inspect by ID and reconsider. That follow-up is not yet counted
as successful. The first cloud provider hit a weekly quota; an explicit operator
runtime switch preceded this success, not automatic failover.

## Correction after full-source retrieval

Follow-up operation `kmsg-323fee895f2a4d65a6ff582ee6338496` succeeded. Its
actual tool receipt uses the exact proposal ID and returns all four original
source texts. The answer explicitly retracts the earlier inference that source
text was unavailable, distinguishes missing source_bound stores from available
ordinary facts, and keeps authored claims separate from independent verification.
The full-read operation, tool response and corrected answer are retained. This
is one operator-prompted correction in a synthetic-content scenario, not evidence
of autonomous error detection or broad semantic quality.
