# Linux TUI probe adapter smoke

[Run 36265260527](https://github.com/jeong-sik/masc/actions/runs/36265260527)
completed at observer `91905edec1b431446b3b268c4aca609b11dc6e7c` on Ubuntu x86-64.
Artifact `10913378337` has ZIP SHA-256
`0f8a65286029d02d806d80809f43aff93bc21e7acb4744de8c68c231e9d3184d`.
All 11 original members are retained under `raw/`, with checkout-prefix-only
normalization and original/public hashes. `files.json` checks stored files.

The two verified manual Linux probe artifacts are 10913715720 / 10913895110,
source `63b6a34a2e5d8a5388ff8da6088fb6755e81506f` /
`6420fbe9e7e15a1cd24d95cda83b1a385f008a58`. Their product diff is the dashboard
worker-support builder; no TUI source optimization was compared. This single
baseline-then-candidate pair is **adapter plumbing proof only**, not a speedup
or causal performance experiment. All observed acknowledgements exceed 0.1 ms.

Each session completed two cycles of ten individually acknowledged input
transitions: 40 total cursor, page, wheel and Info-scroll frames, plus the draft
preservation assertion in each session. Alpha/beta metadata and 250 retained
Channels were acknowledged before measurement; both returned to Info. Root
revalidated every receipt, preflight/input identity, source hashes, binary
hashes, stdout JSON and all ten per-action summary rows. Both stderr files
are empty and internal frame-timing logs are present. Successful scenario
completion includes the helper's TUI reap and terminal-mode restoration checks.

Whole-session child CPU includes startup, navigation, draft entry and shutdown;
it excludes Python observer CPU and is not render-only CPU. The driver recorded
LANG/PATH as its inherited scenario environment keys. The fixture helper adds
its owned workspace/endpoint, test bearer, TERM and frame path. No real MASC
server or Keeper process was started by this PTY scenario. Output acknowledgement
is not physical display latency or production-runtime proof.

The eight receipt/fixture tests (38 subtests), Python syntax and diff checks
passed locally. The CI job also ran the receipt tests before the Linux sessions.
Local actionlint 1.7.12 did not return a verdict before its owned process was
terminated after several CPU-busy minutes; no local lint pass is claimed.
Required PR CI on a later evidence head remains separate.
