# Authentication and cancellation while reading chat HTTP errors

Base: `1662549e1b17ec431a85b9859c86f172823eb555` (#42414).

## Failure

The acquisition listener ended when headers arrived, while the SSE reader listener started only on successful responses. Between these scopes a failed HTTP response was consumed by Response.text without cancellation ownership. Real ReadableStream fixtures at status 401 and 500 became locked and remained uncancelled after token replacement. The final fixtures were also run in an isolated base worktree and failed at missing body cancellation; explicit body error cleanup prevents a stuck test.

## Change

The shared error-response decoder accepts the existing AbortableRequestOptions contract. With a signal it uses a native byte-preserving TransformStream pipe feeding native Response.text; the existing structured-error decoder and metadata semantics remain unchanged. Native pipe cancellation owns the source cancellation and lock cleanup. Signal abort reasons are rethrown rather than converted into empty error information. The path without a signal retains existing behavior.

Keeper error-body consumption has its own admitted authentication scope and composes caller cancellation. Each listener is released in finally before intentional 401 token bootstrap and the next attempt. Stale body outcomes are rejected with the existing typed authentication-superseded error.

## Checks and limits

248 focused tests passed across api/core, api/keeper, keeper-actions and Copilot. TypeScript noEmit and diff-check passed. Coverage includes 401/500 auth withdrawal, caller body abort, pre-aborted unread-body disposal, UTF-8 byte splits and structured auth/config metadata; existing typed 401 retry cases also pass.

This is actual in-process ReadableStream cancellation/lock evidence under mocked fetch. It is not browser network termination, server operation cancellation, installation, screenshot or named-provider runtime proof. No whole-suite, CI, formal approval or merge evidence is claimed. Account-scoped caches and live async/broadcast/interleaved continuity remain work for the full active chat goal.
