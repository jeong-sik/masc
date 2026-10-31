# Keeper official-client response reconciliation

Baseline: `e3fb4903ff9f92c6b9f724f6880e56eb5a57de30`.
Candidate source and test commit: `5d14c031846748ae38c228c8fdd62d5b1721d2a5`
(source blob `a20796b71d9b6b92b7abc8e388f0e07512e58795`, test blob
`9cd0ee35c56e50b95b64814b2ce38fd972c409ea`). `finish_response` reuses the
raw and current strings it already inspected instead of copying those buffers
again for remainder calculation. When raw is a prefix, equality has already
been excluded, so it is a strict byte prefix and its suffix needs no second
prefix comparison. Empty, equal, earlier-message, current-prefix, unrelated
response and tool-row behavior stay the same.

## Reproduction and scope

On arm64 macOS 26.6.1 with OCaml 5.5.1, `ocamlopt -O3` without flambda,
[`reproduce.py`](reproduce.py) compiles the exact old/new modules and unchanged
public interface, and extracts the added case from the repository's
`test_runtime_antigravity.ml`. The single extracted case passed against both
modules. The full repository test suite was not run locally.

```sh
python3 docs/evidence/keeper-stream-reconcile-state-20261030/reproduce.py \
  --baseline e3fb4903ff9f92c6b9f724f6880e56eb5a57de30 \
  --candidate 5d14c031846748ae38c228c8fdd62d5b1721d2a5 \
  --out artifacts/keeper-stream-reconcile-state-20261030/reproduction
```

The same script compiles both complete module implementations without their
interfaces and compares 60,000 seeded `forward`, `tool_row`, completion,
remainder and finish operations, checking returned bytes and retained internal
state after each. Inputs include empty pieces, newline boundaries, split UTF-8
bytes, earlier messages and both prefix forms. This passed in isolation; no
provider, event bus, actual Antigravity process or Keeper turn was run.

## Captured samples

[`samples.csv`](samples.csv) contains seven alternating samples per fixture.
Each constructs two messages outside the measurement and repeatedly calls only
`finish_response`; sizes are bytes per message and final input is prebuilt.
Median results:

| Fixture | CPU old → new | Wall old → new | Allocated bytes old → new |
| --- | ---: | ---: | ---: |
| 4 KiB messages, raw prefix, 5,000 calls | 75.401 → 39.052 ms | 75.667 → 39.101 ms | 103,480,096 → 62,200,096 |
| 4 KiB messages, current prefix, 5,000 calls | 23.260 → 20.848 ms | 23.325 → 20.876 ms | 124,040,096 → 62,440,096 |
| 1 MiB messages, raw prefix, 20 calls | 74.663 → 38.289 ms | 74.947 → 38.356 ms | 104,862,016 → 62,917,696 |
| 16-byte messages, earlier message, 100,000 calls | 2.578 → 2.642 ms | 2.600 → 2.652 ms | 12,000,096 → 12,000,096 |

The earlier-message sample is a negative timing result; equal-response paths
also retain their prior buffer copies. These synthetic timings and allocations
do not establish overall Keeper latency or memory use. In particular,
`Keeper_antigravity_runtime` separately calls `remainder` before
`finish_response`; that work and the provider and event delivery are not in
these samples.

[`double-prefix-samples.csv`](double-prefix-samples.csv) preserves the earlier
candidate that reused the strings but called `suffix_after` after already
checking the raw prefix. The final implementation removes that redundant
check. Add `--initial` to the reproduction command to reconstruct the exact
earlier candidate (SHA-256
`182484c50d92b5be97210987777de4083fa4f1dc1b8d537fcae1b56e874e8ed7`);
the extracted regression case in that replay is the later added test.
