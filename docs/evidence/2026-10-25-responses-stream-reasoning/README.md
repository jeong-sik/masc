# Responses streamed reasoning and owned replacement

Relates #27924, #45950; immediate source base `28a741cc5b7759c2176293ed88611764275e2abb` (#45932).

## Actual failure

Regression-only `3d640e1fab961d01cedae15deff1247e2d44ab2c` compiled and ran 20 public SSE cases in [40194434684](https://github.com/jeong-sik/masc/actions/runs/40194434684): **13 failures and 7 passes**. The failures reproduced full-history loss, summary/full mixing, ordering, authoritative-boundary handling, contradiction/truncation/explicit-empty/missing-item acceptance, whitespace handling and item identity. A failed case proves its reached assertion, not all later assertions.

## Changed behavior

The private immutable reconciliation core keeps separate Summary and Full channels and indexed part fragments per native item. Nonblank Full replaces Summary in one unsigned canonical thinking block. Ordinary same-part deltas append; channel switches or part reordering produce an explicit ThinkingSnapshot. Repeated snapshots must preserve observed prefixes and parts. Omitted channels preserve evidence; explicit empty/truncated/conflicting data fails. Opaque objects remain authoritative and cannot be replaced by late plaintext. Item identity and final native grouping are checked.

The new replacement is admitted only on an open unsigned Thinking block. Keeper publication requires an exact response generation/scope and block index. Journal JSON and AG-UI encode the owned event; TUI and Dashboard replace that block while preserving sibling blocks and other responses. Anonymous/indexless existing stretches still append in their source order.

The secret filter clears the old public thinking block and restreams replacement through a fresh streaming redactor. Later deltas share that owner, so a secret split across replacement/delta is withheld and redacted. No raw opaque contents are rendered.

## Checks and limits

Implementation `ac826936a475d1370629a66b774a4c1636034187` failed compilation in [40194866371](https://github.com/jeong-sik/masc/actions/runs/40194866371) on warning4 fragile-match in snapshot admission. No suite execution is inferred. `60e9017be50b97e7932032dcf443180ac1a89f4c` enumerates rejection states explicitly and removes an EOF whitespace issue. The next run [40195195854](https://github.com/jeong-sik/masc/actions/runs/40195195854) at that exact head also failed before suite execution: two exhaustive Live.delta consumers in TUI log/types omitted Thinking_snapshot. The correction includes those and six live app dispatch/discard branches.

A further direct-source audit found the strict TUI stream projection rejected the new event name even though the live decoder understood it. It now recognizes the event, requires exact response ownership and accepts an empty clear snapshot emitted by the redactor. Its existing all-current-events fixture includes an owned empty snapshot; an additional behavior case rejects an unowned snapshot. The older source verdicts missed these consumer failures and are superseded.

Runs40195434070 (5a801110ec3d961e6ab04d5242b77a5b763a3024) and40195465261 (1e665df9993b1a64848808a5adc1afaf24eacb5b) selected only strict projection while the above log/type misses still existed. Neither certifies the final source. Corrected seven-suite [40195602634](https://github.com/jeong-sik/masc/actions/runs/40195602634) targets `46f864170a4f4744436f599bfd06f510fb496dd7`; its actual result is recorded separately after inspection.

Dashboard keeper-stream Vitest initially produced 137 passes and one failure: owned replacement lookup incorrectly folded anonymous thinking stretches across an intervening tool. Restricting cross-stretch lookup to explicit response plus block index corrected this. The same command then passed **138 cases**. New cases exercise owned replacement with a sibling and rejection of an unowned wire snapshot.

The 22 current SSE cases include sync/cache/message conversion, canonical Checkpoint message bytes written to and read from an actual temporary file, and subsequent request replay with tool output and a later user message. This is not whole-Agent restart. Root selected suites cover secret replacement, journal codecs and TUI transcript data. The redactor and UI tests are separate component checks; a joined redactor→journal→UI execution and visible browser/TUI proof remain unverified.

No local Dune build, full regression, shipped MiniMax Responses declaration, live HTTP acceptance, installation, deployment or whole-issue completion is claimed. `gh stack submit` reports Native Stacks disabled for the repository; REST PR stack metadata is null. The PR therefore retains the exact parent branch as base.

All changed OCaml files were parsed with `ocamlc -stop-after parsing`; this is syntax evidence only. Full source SHA256 values bind the implementation/fixtures independently of later evidence-only commits. No typecheck or local build was performed.

## Observed strict TUI execution

[40195465261](https://github.com/jeong-sik/masc/actions/runs/40195465261) checked out exactly `1e665df9993b1a64848808a5adc1afaf24eacb5b` and completed SUCCESS: **50 actual strict-projection cases**. The all-current-events fixture with owned empty snapshot and the unowned-snapshot rejection both passed. The retained excerpt carries the raw-log SHA256. This selected suite does not compile the separate log/types consumers that failed at60e and were fixed at46f; its success cannot certify them or the seven-suite run. The projection source/fixture is unchanged at46f and later evidence-only heads.

## Observed corrected seven-suite execution

[40195602634](https://github.com/jeong-sik/masc/actions/runs/40195602634) checked out exactly `46f864170a4f4744436f599bfd06f510fb496dd7` and completed SUCCESS. Actual executable summaries: public SSE22 + sync reasoning16 + phase replay24 + secret redaction33 + chat event journal32 + TUI transcript107 + strict projection50 = **284 cases**. Full-history/message-file replay, split-secret replacement, exact response/block replacement and strict missing-owner rejection assertions were reached and passed. The retained raw-log digest and assertion/summary excerpt preserve the execution identity.

This establishes the selected backend and root consumers, including the repaired log/types compilation, on that source. All55 recorded source/fixture hashes remain unchanged by later evidence-only heads. It is not a full executable/release build, full regression, joined redactor→journal→TUI execution, rendered UI, installed runtime, provider HTTP or native activation proof. The separate50-case run is a prior execution of one of these suites and is not added again to284.
