# Actual Kimi review of current PDF renderings

The repaired CI binary `4a6723c3f54a597a52db26276635b4a2b8b6e871` ran in a
fresh isolated base at port 18946. A controlled producer submitted copied
artifacts; **the verifier was the actual Kimi API**, model `kimi-for-coding`,
selected as `kimi_coding.kimi-for-coding`. Its raw request bytes were forwarded
unchanged through a recording proxy to
`https://api.kimi.com/coding/v1/chat/completions`. No verdict was injected.
All upstream request/response pairs and their hashes are included. Credentials
were held in memory and excluded from records.

The copied source PDF has 136937 bytes and SHA-256
`bb8687f70944e374fde9492eb845446cbf3f19385dc163bed5abb5a655b93f86`.
The three received PNGs were 166776, 190109 and 134793 bytes and match the
source receipt and submitted snapshot hashes. The original four criteria were
passed unchanged. No human visual-review conclusion was supplied to Kimi.

Kimi reported APPROVE for all four criteria: three pages, readable Korean with
no missing glyphs, no overlapping/clipped text, and separation of synthetic
examples from performed verification. The authoritative primary Task is done;
verification `vrf-e98a49e8b919f2e8d0b3b7d180861d83` joins the immutable request,
committed system-LLM verdict and completed verifier registry. Producer operation
`kmsg-d88421644c25a0079fceb3f3b3e0cd0c` is Succeeded. This is the isolated review
of these exact copied bytes, not a claim that the original Task was transitioned
or that a human final confirmation occurred.

## Live lookup limitation

Kimi explicitly reported failed live file lookups and based its decision on the
submitted snapshots and attached images. Those failures remain in the raw
responses and verifier tool registry: the correct host paths existed, but the
Docker guest could not read them. The probe output lived under `/private/tmp`,
while the active Colima VM shared only `/Users/dancer` via virtiofs. The producer
never needed a guest filesystem operation, so snapshot ingress succeeded while
later Docker reads failed. This is a probe placement/infrastructure mismatch,
not evidence that the PDF or summary was absent. Future live-lookup probes should
use an output directory visible to the selected Docker daemon. No live config
was changed and port 18937 was untouched.

## Observer correction and shutdown

The first harness assumed submission ref order. The Task contract canonicalized
the same six artifact references, so an assertion failed after the real approval.
Its cleanup preserved the server/provider. The unchanged run was then checked
by exact artifact-reference multiset, snapshot image bytes, primary Task,
authenticated operation observation, committed verdict and public verifier-run
registry. Only after all terminal joins passed was the owned server stopped.
No model rerun occurred. `receipt-before-observer-correction.json` and the exact
`harness-at-run.py` preserve the initial observer error; `receipt.json` and
`external-observer-receipt.json` state the corrected accepted result. The reusable
script now accepts canonical ref ordering and reports descriptive assertion errors.

`source/` contains the actual PDF, renderings, measured summary and copy receipt.
`runtime/` contains recorded evidence. Request wire JSON is gzip-compressed without
modification; `upstream-roundtrips.json` gives its decompressed SHA-256 and joins
the actual upstream response. `sha256.json` covers every stored file except itself.
The CI binary manifest has `release_validated=false`; this does not certify a
release or replace independent human inspection.
