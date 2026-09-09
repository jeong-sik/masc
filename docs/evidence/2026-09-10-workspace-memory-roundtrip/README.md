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
