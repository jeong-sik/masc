# Original callback capture component evidence

This private candidate follows current whole30 `40b1b707` plus the separate
optional-metadata/decline response `f89d8442`. These are source and component
checks, not an installed runtime, real provider account or native keychain run.

The existing Python operator fixture runs the actual Worker, Connector and
owned temporary private store with fake provider/opener ports. The pre-capture
write-failure case preserves the original pending state and can retry it. An
exchange failure after capture has a capture receipt but remains reconciliation
required. Redelivery then performs no second code exchange. Directory-fsync
failure suppresses the receipt. Only direct exact cancellation acknowledges a
decline; a disconnected view or lost decline response does not reconstruct one.

`generate_receipts.py` runs those real producer components with fabricated
credentials and produces `backend-receipts.json`. The packet records producer
source hashes, original pending identity, a pre-capture failure, captured and
redelivered replies, and the one provider-call count. It contains fixture values,
not user data. Run it from the repository root with Python 3.

From `dashboard/`, run the existing Vitest command for these three files:

```
src/api/lane-addon-operator.test.ts
src/components/lane-addon-operator.test.ts
src/components/lane-addon-operator-callback.test.ts
```

The actual component's transport port replays those Python replies. A helper
executes the literal script from the actual OCaml callback route in a synthetic
window; it does not copy that script's state machine. The coupled case retains
the page after the actual pre-capture failure and clears/closes it once after
same-request redelivery yields the matching stored-key receipt. Separate cases
cover manual form failure/retry, wrong connection, absent/malformed receipt,
spoofed source/origin/state, Inspect replacement, credential change, navigation
while a return is queued, and unmount with a late reply.

Source-before checks on `f89d8442` fail the actual script's premature URL clear
and the actual component's missing original-return retry. The candidate has
26 Dashboard checks,21 operator checks and29 existing OAuth checks passing.
Six changed TypeScript roots were checked semantically and the OCaml route
was parsed; these are not whole-project type/build or Native/HTTP/MCP results.

Protected-store `b228` integration requires the existing nonblocking
`PrivateStore.locked(blocking=...)` contract to move from its later introducing
layer into provider65, with its later duplicate absorbed. There is no compatibility
wrapper. This packet's owned file-store receipt results do not execute that native
backend. Original authority loss, keyless/account-pinned recovery and pathname
allocation P2 remain outside the demonstrated result.

An independent source review found two further counterexamples in frozen `8dd942`:
captured storage could still block later window actions while waiting for a lost
page-cleared message, and exact cancel could auto-dispatch a stale queued return.
The original actual component fails both new selected checks. The response
preserves confirmed storage even when postMessage to a closed page fails, releases
captured dispatch ownership for later actions, and rechecks pending identity after
every mutation. Separate closed-page and lost-cleared cases permit the next
operator window without claiming that the old page cleared or closing it; the
cancel case preserves the original return without an automatic third RPC.

The private whole-stack composition regenerates the checked-in receipt packet
through the actual protected-store read-back/reference edge using explicit
process-local `MemoryRecords`. Its source hashes bind the composed Python
producer. This exercises no native OS credential backend; the original SDK
file-store source results above remain a separate historical scope.
