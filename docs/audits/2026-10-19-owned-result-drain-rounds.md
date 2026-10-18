# Original-owned results between finite shared queue prefixes

Source comparison base: `629e10bfec84150984a9163b06981b8e731ab7c5` (#43784).
Source boundaries only; no executed runtime, screen or speed sample.

## As-Is / To-Be

The drain tried the shared stream on every selection. Only an empty stream let
it consider Ask POST/final results, Runtime form saves, Keeper settings saves,
runtime assignment or Keeper creation. A shared producer that always supplied
another item could indefinitely postpone these already recorded facts. The
fallbacks also searched sources in priority order for just one owner per take.
This identifies a source scheduling condition, not a reproduced loading cause.

`Delivery_round` now retains an immutable scheduling value across both drains
and later input-loop passes. At round start, it captures the stream's actual
queued length. It consumes exactly that FIFO prefix, then collects all ready
owners from the six existing sources into one finite set of message values.
New shared arrivals cannot enlarge the prefix; later publications cannot enlarge
the collected set. Completing the round returns to the caller even when the
stream has remained nonempty. The next drain may start another round using the
same per-pass deadline or a later pass's fresh deadline.

| Source boundary | Before | After |
| --- | --- | --- |
| Eligibility of retained outcomes | Shared stream must become empty | Captured FIFO prefix must finish |
| Original-owned source kinds | 6 fallbacks | Same 6, collected once per round |
| Ready owners from each kind | First matching owner, repeat priority search | Every matching owner in that collection |
| New shared arrivals before owned recovery | Can keep extending shared work | Belong to next prefix |
| New owned publications during delivery | Can restart higher-priority search | Belong to next collection |
| State across input/deadline pauses | No finite delivery boundary | Exact prefix/remainder retained |
| Pre-/post-input deadline | One shared deadline | Same one, also checked after collection |
| HTTP/model calls, Tool effects, retries | Existing paths | Unchanged |
| Queue capacity, input cadence, arbitrary take caps | Existing values, no take cap | Unchanged, no new cap |

The prefix length and collected membership come from actual queues/owners, not
a fixed batch size. Under continued loop progress with usable deadline time and
terminating application callbacks, a fact collected in a round has only that
round's finite preceding work ahead of it. This is a structural bound on work,
not a time bound or measured latency improvement. Collection scans existing
pending owner sets once; it is synchronous and can itself overrun a deadline.
The deadline is rechecked before its first result is applied. No whole-stream
drain, timer, background delivery fiber, new executor or request generation is
introduced. No in-flight application is interrupted.

## Authority and retention

Identity withdrawals in the captured prefix apply before owned collection.
Identity messages arriving later keep FIFO order in a subsequent prefix; this
does not promise that every currently queued withdrawal preempts owned facts.
Every delivered result still uses the existing original request and current UI
workspace/read admission. A keyboard action or withdrawal during a paused round
cannot grant captured messages new ownership or a replacement read nonce.

Ask POST offers remain canonical until normal application consumes them. Final
offers are reserved into the round once; their raw facts remain in the original
session-owned cells/history. They still recreate Workspace_scoped using the
original authority and nonce-or-None, then use the existing operation projection.
The POST/final distinction, read retirement, foreign workspace rejection,
current/inflight terminal guard and no-fabricated-result closure remain intact.

Runtime and Keeper result messages carry the sampled original owner/status/time.
A later status publication stays in its atomic cell for a later collection.
Existing monotonic application prevents captured progress from regressing a
newer or terminal status already applied through another path. Creation still
consumes its own pending owner only after terminal application. No saved fact
authorizes a current surface refresh by itself. Collection reads owners in
sequence; it is not a simultaneous snapshot across producers.

Existing ready-to-UI-application logs retain the original observed timestamp.
They include round and input pauses and do not measure paint, pure HTTP RTT,
Keeper useful work or model execution.

## Authored evidence and limits

A compound request/state scenario uses the production delivery scheduler and
owned-message collector with an actual bounded Eio stream. It refills shared
traffic after each take so the stream remains nonempty. An initial prefix
withdraws read authority; a spent-pass probe retains the remaining prefix; a
collection crossing the deadline retains its unconsumed message set. Multiple
Ask owners and creations share the round with Runtime form, settings and
assignment outcomes, including refused/unconfirmed results. Original POST facts
survive refused GET projection. A subsequent foreign authority cannot authorize
those saved configuration results as current. A creation published just after
collection waits for the next round, then progresses while shared traffic
continues. Existing cancellation/full-queue scenarios use the collection APIs.

All scenario assertions are authored but unexecuted. The deadline probe supplies
a caller permission callback; it is not an executed input-loop timing sample.
The fixture applies production state/projection functions, not the full TUI
dispatcher or real HTTP endpoints. No wording, layout, row-order, snapshot-output
or PTY test is added. Parsing and diff/changelog checks do not establish typing,
runtime fairness, independent approval, merge, installation, visible UI, loading
resolution or matched Before/After speed. Failed, cancelled, interrupted and
unfinished runtime samples remain required in any later matched measurement.
