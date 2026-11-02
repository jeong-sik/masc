# Native account selection: first product execution

The targeted **Test** workflow [run 41379588690](https://github.com/jeong-sik/masc/actions/runs/41379588690)
checked out `79158c71e1fcc250e0f7b55f1b4edfb6906753dd` from
`fix/frozen-native-account-selection-20261102`. Its actual conclusion is
**failure**. Twelve explicit suites produced **668 OK / 1 FAIL / 9 SKIP**.
The native account-selection suite completed **27 PASS / 0 FAIL / 0 SKIP**.
[selected.txt](selected.txt) preserves the checkout, target list, case records,
failure diagnostics and summaries. [receipt.json](receipt.json) records the
raw and selected capture digests; [suite-results.json](suite-results.json)
partitions the case records by actual suite start markers.

The sole framework failure is the per-keeper routing case for distinct native
accounts. It receives the expected `Execution_unbuildable` for a Codex binding
with empty HOME and CODEX_HOME, then fails because the diagnostic no longer
contains `account-home`. The follow-up fixture checks that typed rejection
directly. Other error kinds and successful native materialization still fail
the negative control; the preceding distinct-account checks and following
unrelated HTTP success check remain in place. Production diagnostics are not
changed to satisfy a text assertion.

One Codex serial-tool-fence case is recorded OK even though a callback assertion
appears in a WARN. The old fixture checks the same pre-release state on every
text delta: the first `MASC_` delta releases the tools, then the completion's
`SUBSCRIPTION_OK` suffix repeats the assertion after those tools have run. The
client catches callback exceptions. This limits that old case's success evidence;
it does not establish a production fence defect. Source inspection confirms that
the later remote `424a6cdeee9d32cbd7d84fb737b1d3e18f6e4d1b` fixture already records
the first observation and asserts outside the callback. No execution result is
transferred to that rewritten source.

The raw capture also reports an already-resolved promise in the idle-handoff
fixture, which signals progress on repeated text deltas. Both observed callback
warnings are retained in [callback-warnings.txt](callback-warnings.txt), with a
separate derivative digest in the receipt. The original selected capture retains
its unchanged bytes; it includes the assertion warning but omits this promise
warning. Framework OK counts do not certify warning-free callback execution.

The nine SKIPs are one Claude and eight Codex live-subscription controls. They
are not passes or real-account observations. All reported native selection
checks use owned synthetic contexts and child-environment projection; they
do not exercise a real vendor model turn.

[source-inputs.json](source-inputs.json) retains the request-time 59 named inputs,
five source-tree identities and twelve target names. The raw job capture remains
in ignored artifacts in the original campaign checkout. The selected file here
retains its exact captured bytes and independent digest. Inspected fixture values
are synthetic; no live credential or private runtime conversation is retained.

The earlier regression-only baseline at `74740cfe683856b85ceb12bee2b572ebdeae5c4f`
ran eight cases with 2 PASS / 6 FAIL / 0 SKIP. Its fixture source differs from this
27-case candidate, so these are not an identical-fixture before/after pair. The
remote stack was subsequently rewritten onto newer main content. The retained
results certify only the actual `79158c71` checkout, not the current remote head,
this evidence/fixture follow-up, full regression or whole-stack integration.
Issue [#27898](https://github.com/jeong-sik/masc/issues/27898) remains open.
