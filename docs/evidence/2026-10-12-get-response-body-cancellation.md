# GET cancellation remains connected through response consumption

Parent: `cce7eeb9126a1ee47d6975bec8cfc3a91197896a` (#42441).

Real core/operator refresh fixtures reproduced cancellation being detached after headers: replacing credentials during a stalled snapshot/digest response body left the actual fetch signal un-aborted (`/tmp/operator-get-body-red-20261012.log`). Controlled fetch models native fetch's open body error on abort and releases its stream in finally; this is client API evidence, not a real socket measurement.

Core GET now consumes the response through fetchWithTimeout's existing consumer contract. Upstream cancellation and the configured request deadline therefore remain connected until body interpretation completes, including server error and warm-payload paths. No new deadline is introduced. Malformed/empty/read-failure response behavior remains in core tests.

The first candidate exposed another failure: aborted body reading was wrapped as a generic ApiRequestError, losing typed timeout classification (`/tmp/operator-get-body-timeout-red-20261012.log`). JSON and error-body parsing now preserve platform AbortError so the existing transport helper can distinguish caller cancellation from its configured timeout. Final success/error response fixtures use the configured GET timeout and assert ApiRequestError.timeout, method and path. ApiRequestError does not expose a timeoutMs property; an initial fixture assertion of that nonexistent field was corrected rather than changing the public class.

Focused checks completed on the final restored source: `npx vitest run src/operator-refresh-http-ownership.test.ts src/operator-actions.test.ts src/api/core.test.ts` passed three suites / 105 tests (`/tmp/operator-get-body-focused-20261012.log`), and `npx tsc --noEmit` exited 0. Reverification followed the parent fragment checkout so evidence is bound to the complete restored candidate.

This changes the shared GET body lifetime. Other HTTP verbs/getWithResponse, transports ignoring AbortSignal, reentrant credential notification, already-visible account projection/pending/log partition and downstream UI remain separate work. No live provider/server, screenshot, installation, CI or formal approval is claimed. The full chat goal remains active.
