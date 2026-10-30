# Native TUI refresh: controlled before/after

The current candidate displayed changed Keeper health while two unrelated
readers were still waiting. The baseline kept the previous health until those
readers settled. Both native binaries used the same baseline backend and local
dependency cohort, with separate private workspaces and ports.

This is a controlled dependency-delay experiment. It is not a production
speedup, a model-preparation benchmark, or physical terminal paint latency.

## Source and execution identity

| Role | Frozen source |
|---|---|
| Baseline TUI and common backend | `683c7950682b45a2591002e09f654515ccf02155` |
| Candidate TUI | `f7632e71601da3ce6c7b5a5e8a6b528bcf42fa4c` |

The baseline runtime artifact is from Actions run `38911700463`, artifact
`12051260858`. The candidate is from run `38918375925`, artifact `12054406530`.
Selected ZIP payloads matched their producer's `SHA256SUMS`, and the executed
binaries' embedded commits matched the frozen sources. The complete ZIP digest
was not verified by the selected-member transfer.

The selected binaries require sibling shared libraries. Their first identity
attempts failed because these packaged libraries were absent; the recorded
failures are in [native-initial-identity-attempts.json](native-initial-identity-attempts.json).
Both arms then used the same private copies of locally installed Homebrew
libraries. Their original paths, checksums and load dependencies are retained in
[native-local-dependencies.json](native-local-dependencies.json). This does not
qualify the original relocatable runtime package.

The current candidate's state suite passed in run `38918370690`, and its native
build succeeded in run `38918375925`. These observations cover the same candidate
SHA. Independent approval, merge and live installation are separate and are not
claimed here.

## As-Is and To-Be

| Boundary | Baseline | Candidate |
|---|---|---|
| Waiting refresh | Connection status remains visible | Connection status also names pending readers |
| Warm Keeper reading | Roster waits for the full bundle and final identity probe | A successful workspace-bound roster settles its own receipt before unrelated readers |
| Terminal copy | Applies the roster with the bundle | A consumed roster receipt cannot replay the roster or its dependent Item refresh |
| Cold workspace | Terminal bundle confirms authority | Unchanged; early delivery still requires an already confirmed matching workspace |

## Matched input

Each arm initialized a new workspace with the same baseline server executable.
Two metadata records came from the baseline's existing
`test/fixtures/item-http/keeper.json`; their names and trace IDs were replaced
with private fixture identities. Their TOML profiles use manual activation, so
no Keeper model turn or sandbox job is started by this scenario.

The default unbooted `imp` declaration remains visible and unread. It is not a
healthy runtime result, and it is not included in the two returned runtime rows.
The three visible Keeper names and the two observed runtime rows are different
counts.

After cold readings settled, keyboard navigation opened the Keeper table. At
the warm `r` action, the local proxy delayed `/api/v1/dashboard/briefing` and
`/api/v1/operator` by two seconds. The other routes continued to the real
isolated backend. In the roster response, the proxy changed the two fixture
rows from `health=offline, paused=false` to `health=failing, paused=true`. This
is explicitly synthetic input; no real Keeper became failing or paused.

The candidate's newer-source footer warning was retained. The baseline backend
was deliberately shared between both arms; it was not relabelled as the newer
candidate. The runs at the two viewports overlapped on the same host.

## Before/After observations

One matched changed-health sample was collected per arm and viewport. The
scheduled captures are approximate offsets from the warm key action. State
admission and terminal refresh durations use the candidate's own monotonic
dispatch clock and join through the same `started_ns`.

| Viewport | Baseline scheduled 0.5s capture | Candidate scheduled 0.1s capture | Candidate roster admitted | Candidate full refresh |
|---|---|---|---:|---:|
| 120 x 36 | Previous `offline` rows | New `failing` rows; pending readers visible | 54.594 ms | 2046.113 ms |
| 80 x 24 | Previous `offline` rows | New `failing` rows; pending readers visible | 78.039 ms | 2109.435 ms |

Both baseline captures show the new health at the scheduled 2.5s capture. The
baseline has no roster-admission timer, so its exact admission duration is
unknown. Candidate admission occurred about 1.99s and 2.03s before its own
terminal refresh, respectively. These intervals demonstrate removal of the
imposed sibling wait; they are not a general speedup percentage or a latency
distribution.

The PNGs render captured native PTY cell state using pyte, Menlo and Apple SD
Gothic Neo. They are not a source-only renderer preview or a physical terminal
screenshot. The associated ANSI-derived frame journals and text captures are
retained beside them. The frames were inspected manually; no UI text, layout or
row-order assertions were added.
Text frames deliberately retain their terminal-cell padding, including trailing
spaces and blank rows.

| Viewport | Baseline during wait | Candidate during wait | Baseline after wait |
|---|---|---|---|
| 120 x 36 | [0.5s frame](baseline-120x36/warm-0.5.png) | [0.1s frame](early-roster-120x36/warm-0.1.png) | [2.5s frame](baseline-120x36/warm-2.5.png) |
| 80 x 24 | [0.5s frame](baseline-80x24/warm-0.5.png) | [0.1s frame](early-roster-80x24/warm-0.1.png) | [2.5s frame](baseline-80x24/warm-2.5.png) |

Machine-readable timings, request observations, binary hashes and attempt
interpretations are in [observations.json](observations.json). Each selected
arm directory includes the frame journal, request observations, roster bodies,
execution receipt and refresh log. The manifest binds the retained files.

## Failed and non-demonstrating attempts

Fourteen collector attempts were made: two failed and twelve produced captures.
Twelve captures do not mean twelve successful changed-data comparisons.

| Attempts, per arm | Result and implication |
|---|---|
| 1 | Collector failed on an unsupported private terminal status request; fixed the collector and retained the failure |
| 2 | Empty roster: useful for the pending-reader display, insufficient for changed-data availability |
| 3 | Navigation overlay consumed `r`: warm refresh was not exercised |
| 4 | Valid Dashboard refresh and early state admission, but the changed pause field was not visible in that view |
| 5 | Valid Keeper-table refresh and early state admission, but the pause field was not visible at these widths |
| 6 and 7 | Changed health was visible; these are the paired observations reported above |

All collector receipts are retained in `attempts/`; the full local execution
directories also preserve the earlier captures and logs. No unfinished
collector remained when this report was assembled.

## Reproduce manually

Use macOS arm64, verified binaries for the frozen SHAs, and the same explicitly
recorded dependency cohort. Copy the observer and fixture into a new private
directory, then install its observation dependencies there:

```sh
experiment=$(mktemp -d)
cp docs/evidence/2026-10-17-tui-refresh/observe-native-refresh.py "$experiment/"
cp docs/evidence/2026-10-17-tui-refresh/keeper-meta-fixture.json "$experiment/"
python3 -m pip install --target "$experiment/pty-python-dependencies" \
  pyte==0.8.2 wcwidth==0.9.2 Pillow==12.1.1
python3 "$experiment/observe-native-refresh.py" \
  --server /path/to/verified/baseline/masc-macos-arm64 \
  --tui /path/to/verified/candidate/masc-tui-macos-arm64 \
  --arm candidate --surface keepers --columns 120 --rows 36 \
  --output "$experiment/candidate-120x36"
```

Run the baseline with its own verified TUI and a different output directory;
repeat at `--columns 80 --rows 24`. Inspect the actual frames and receipts.
The observer always retains a failed attempt and stops only the child process
groups it created. It does not install or restart the operator's runtime.

## Remaining goal work

Cold-start authority, other incremental datasets, actual model-preparation
roundtrip reduction, broader resource-owned recipe/Skill concurrency, typed
held-job reactivation and a matched real-model cohort remain unfinished.
The preparation integration run `38913807155` also remains a recorded failure
at the fixed-child scenario; the passing HTTP component suites do not clear it.
This report establishes the stated warm-roster/visibility behavior only.
