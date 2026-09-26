# Parse footer hint items once per rendered line

The verified native baseline `c7bdc04f78e3b6c09abae94e28852b37f8274da7`
(artifact `10909422480`, [Release 36252626478](https://github.com/jeong-sik/masc/actions/runs/36252626478))
already includes the earlier fixed pin-rule and SGR-copy changes. Its footer
source is byte-identical to PR base `afbeddb74ce810204afdd5716972eeac592e7270`.
The artifact ZIP, manifest/source and all three executable hashes were verified.

## Observed repeated work

A five-second native sample during sustained synthetic Info scrolling still
contains `item_is_pinned`, SGR stripping and `key_atoms` under the footer's
repeated droppable-item search. Source inspection shows that each fitting retry
reparses the retained hint strings, and conflict attempts repeat the parsing.
The empty-conflict probe also classifies hints even when its filter has no
conflicts to inspect. `source-observation.json` records matching sample lines,
profile/source hashes and the matching current base.

The sample supports investigating that path. It is not a per-frame cost estimate,
dominant-bottleneck claim or comparison against previous profiles. The modified
profiling workload performs one roster cycle and 6,000 Info cycles (24,006 input
acknowledgements), retaining 250 Channels bindings. Every new input still awaits
its expected window and complete PTY frame. After the first detail transition,
the profiling variant uses the preceding opposite-window acknowledgement instead
of reconstructing the entire accumulated screen before each input.

Sampling perturbs execution. The raw observation inherits a TUI-only resource
scope from the base harness, but this profiling wrapper also spawns the sampler,
ps and pgrep. Its child CPU totals therefore include those processes and are
not TUI-only CPU measurements; profile.json explicitly records that correction.
The sampler exited zero, the terminal harness returned PASS and reaped its child.
No sampled latency is used as an uninstrumented before/after result.

## Change

A line owns its original hint text and a lazy list of parsed items with their
pin decisions. It classifies each item at most once within that synchronous
line call and shares the result across width/conflict retries. There is no
shared cache or cross-frame retained value. A fitting row without conflicts
never forces item parsing. Whole initial text, spacing, style bytes, priority
order, conflict fallback, status omission and cut-marker policy are preserved.

The lazy is local to a synchronous pure fitter with no fiber yield; it cannot
be shared or forced concurrently across line calls. The four existing tests
that directly invoke internal fitting helpers now construct prepared hints.
Their assertions remain unchanged. Existing footer coverage includes narrow
widths, compound pinned keys, ANSI/Korean text, conflict ordering, position,
action results, literal search status and the Identity tab's controls.

Source and both edited test files pass OCaml syntax parsing and diff checks.
Compiled CI is pending. The [native PTY comparison](comparison/README.md)
completed 600 acknowledged inputs: overall median/p95/max and all Info
aggregates worsened. The PR is draft while a separate balanced six-pair run
checks whether the regression reproduces. No local OCaml
build, speedup, allocation-volume measurement, deployment or 0.1ms result is
claimed.

## Receipts

This directory retains the exact profiling runner/scenario, source identity,
full sample, observations, stdout/stderr and frame report. Large text receipts
are gzip-compressed. The original diagnostic paths are replaced with stable
placeholders; redaction.json records original and published decoded hashes.
Published byte hashes are in files.json.

To repeat the instrumented diagnosis, use observer checkout
`304f5f6f67edcb38e3b2ad5da6759d64f73a4983` and the anchored native artifact:

```sh
python3 run-profile.py <observer-checkout> <artifact-directory> <new-output-directory>
```

The runner uses only owned synthetic fixtures. This does not exercise the live
operator workspace or establish physical-display/runtime continuity.
