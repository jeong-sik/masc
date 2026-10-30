# Restore native Ego wait ownership

The earlier [integration audit](../ego-native-integration/) verified source
`7ee0dd6e`. After those runs, workflow layer commit `e846cbe2780` introduced
16-step, 5-second default, 30-second per-step and 60-second aggregate limits.
It also wrapped SDK calls in `Promise.race`. The merged source had those
additional limits; the earlier runtime evidence does not validate them.

This change removes that added execution policy. Omitted timeouts reach the
SDK without a MASC default; explicit values are forwarded unchanged. The
workflow awaits each SDK settlement, its native waits and the final snapshot.
Native upload, chooser and workflow commands again use the shared SDK session
without a cumulative command window. Explicit host cancellation still stops
and reaps the process. Startup handshake, shutdown grace, output-size and
socket-path boundaries remain.

## Measured evidence

- 22 production-JavaScript tests passed across workflow, target input, drag
  and upload. The deferred-SDK test proves that a later action does not start
  until the previous SDK promise settles. It also checks omitted options and
  unchanged explicit timeout forwarding. Its timeout-zero case is a forwarding
  test with an SDK double, not evidence that real Ego accepts zero.
- `scripts/check-browser-native-workflow-codec.sh` compiled the real codec and
  receipt interfaces/implementations and passed five tests. A known 20-step
  sequence and explicit 120,000ms values survive decoding; duplicate/unknown
  fields, unsafe integer values and malformed effect receipts remain refused.
- All changed OCaml sources/interfaces parse, the tool TOML parses and
  `git diff --check` passes. These do not type-check the full host.
- Independent source review found no production P0–P2 issue. It identified
  the distinction from ordinary target-input transport windows below.

## Installed Ego, two separate local fixtures

At this SDK-only proof boundary the user-authorized continuing space was **20**.
The earlier verified space14 had been retired and was absent from discovery;
no other agent's space was used. Space20 was later found missing, as the input
lifetime follow-up records. The continuing replacement authorization covered
subsequent host verification. Historical space IDs here are not current resume
instructions; the final12c run used30/p1 and normal shutdown removed it.

`probe.mjs` executed production `nativeWorkflow` against a private local
fixture. Nineteen steps completed and its Save click applied once, but the
last wait used `timeoutMs: 0`, which the real SDK rejected as requiring a
positive number. [attempt1-sdk-output.txt](attempt1-sdk-output.txt) preserves
that partial result and the single applied submission. It is not a successful
20-step receipt; the unchanged first probe retains its failed assertion.

The first fixture's local HTTP server ended with that probe. A separately
created second local fixture was then opened in the **same space and p1** by
`round-02.mjs`. This was another test application instance, not a retry of the
first submitted form. It omitted the final timeout, using Ego's default.
[proof.json](proof.json) and [sdk-output.txt](sdk-output.txt) record twenty
completed steps, no failure and exactly one Save in that second fixture.
Seventeen native waits each accepted explicit 75,000ms options; the test did
not spend 75 seconds waiting or establish an unlimited-duration success.

The final viewport snapshot contains `Saved: Ego owns waits`. The independent
SDK [screenshot](native-waits.png) was visually inspected. The recorded
production-JS SHA-256 is
`ff96902e331b3b8ea0e3d07b1d4dcb8ebb2d638218104276bc29ed6b1e29d061`.

## Remaining verification

These new runs prove component behavior and installed SDK execution. They do
not prove this branch's complete host binary, current real Keeper dispatch,
production installation or release. Earlier candidate Keeper evidence remains
bound to its own exact source.

At this layer, ordinary selector/ref input still used the normal transport
reply window. The [input lifetime follow-up](../ego-native-input-lifetime/)
audits and repairs that execution boundary separately, preserving scene,
coordinate and other-browser policies. Neither component proof substitutes
for the current combined host/Keeper execution.
