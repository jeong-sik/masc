# Zen download result delivery — 2026-09-08

A Keeper on source `c067555236735ea9baf55c990c134257a5e0197d` used real Zen through
geckodriver against an owned loopback fixture. The request asked for two different
binary downloads with the same suggested filename and one Unicode file in an iframe.

[Actual call metadata](before.json) records 15 calls, 10 successes and 5 failures.
Zen downloaded Binary A: 40,960 bytes, SHA-256
`90b3b375e4565eb5cf64f68b23809e221918ee6a0b78fac98debf002ffaf2c4d`, matching
fixture bytes. BrowserRead downloads then failed at provider projection with
`tool output artifact storage failed`. The remaining requested downloads, file
reader and model image analysis were not completed. The [viewport](before.png)
is an independent operator capture, not proof the Keeper captured or analyzed it.
Operation Succeeded is not completion of the requested workflow.

The file publisher returns a normalized durable blob reference. Tool_bridge requires
a durable result manifest before projecting such data. The Keeper BrowserRead
producer omitted that step; Execute and composition producers already perform it.
The fix persists the manifest at the BrowserRead producer boundary using the exact
workspace base path. Failed browser reads and ordinary non-artifact results retain
their existing disposition. Manifest persistence errors remain explicit.

The added regression passes a real published binary through the Keeper producer,
provider projection, durable manifest and referenced-byte fetch. It would fail at
provider projection before this change. Local builds were not run. Fresh live
verification of the changed binary must be recorded separately from this failing run.
