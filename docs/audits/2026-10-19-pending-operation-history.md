# Configuration receipt collection independent of settled history size

Source comparison base: `79dc07e3bf92ea484e8f99f6c3612b7834cfd630` (#43787).
Source work counts only; no executed runtime or speed measurement.

## As-Is / To-Be

Finite delivery rounds already kept continuously renewed shared traffic from
extending the current queue prefix. However, each owned-result collection still
read every atomic observation in the retained Runtime form, Keeper settings and
runtime assignment histories, including terminal UI-applied attempts. Their
history retention is required for notices, recovery, revisions and uncertainty;
periodically rereading settled cells is not.

Each history is now an opaque immutable `Operation_history` value containing its
original admission-ordered entries and a derived pending index. The three typed
instances classify only immutable UI-applied status. Atomic worker publication
does not change membership. Checking/previewing/reading/posting owners remain
indexed, including unfinished owners with no new observation. Terminal UI status
leaves the pending index while remaining in history. Recovery changes and status
application rebuild both projections as one value, so callers cannot separately
edit the index or supply an independent pending flag.

Let H be the sum of retained attempts in these three histories and P the sum
still awaiting terminal UI application. P includes owners with no ready fact.
Let F be the retained Runtime form history length.

| Source work per owned-result collection | Before | After |
| --- | --- | --- |
| Configuration histories whose cells are scanned | 3 full histories | Same 3 pending indexes |
| Atomic observations read | H | P |
| Settled historical cell reads when P = 0 | H | 0 |
| Form footer entries visited outside Config | At most 2F | 0 |
| Focused-form entries visited with no focused request | F | 0 |
| History entries retained | H | H |
| New HTTP/model/effect calls, timers or scan caps | 0 | 0 |
| Input-drain deadline and finite delivery round | Existing | Unchanged |

These are source operation counts, not observed milliseconds or a speedup ratio.
History updates still map the retained entries and additionally derive the
pending index. Registration can prepend directly after existing recovery edits.
Notice/recovery searches and form retry checks still read retained history; this
change does not remove every historical traversal or bound session history size.
The extra index holds references to the same immutable attempts, not a second
status or an independently mutable authority.

The form footer previously searched for a focused request and then a visible
recoverable form even outside Config, where every visibility test was false.
It now rejects that view before either history search. Focused-form lookup
checks for an actual focus token before searching, and tests the token before
workspace origin. Those lookups returned no owner in the skipped cases before
the change as well; no notice text, focus/lock decision or authority is added.
With empty history these source counts are zero before and after. This does not
establish a measured cold-start or frame-time gain.

## Ownership and uncertainty

Publication alone cannot retire an owner before the UI sees its terminal fact.
An empty ready collection, read/workspace withdrawal, input recovery dismissal
and a captured intermediate status also cannot retire it. A later terminal
publication remains discoverable through the same original request and timestamp.
Normal monotonic/once-only application still decides whether an observation can
advance. A duplicate old receipt cannot consume a successor's pending entry.

All original request objects, atomic facts, prepared inputs, CAS/revision values,
read/workspace scopes, retained failure outcomes and document revalidation floors
remain in the history. Unknown form retry gates continue using that complete
history, including terminal unknown or unconfirmed-durability outcomes. Removing
a terminal owner from periodic delivery therefore does not permit implicit
retry, prove success, release a draft or authorize a fresh read. Original worker
cancellation and pre-entry-withdrawal publication paths are unchanged.

The two Keeper same-origin configuration exclusion checks use the same pending
projection; their nonterminal-status classification is defined once in the typed
history instance. Runtime form uncertainty gates deliberately retain the full
history path. Notice/recovery ordering remains admission order.

## Authored evidence and limits

A compound request/state scenario captures intermediate results from all three
production collectors, publishes terminal uncertain facts before applying the
captured intermediates, then withdraws read authority before terminal delivery.
It checks that publication/intermediate delivery retain each pending owner and
normal terminal application alone retires it. Original form uncertainty still
blocks implicit retry; original settings text remains recoverable.

Explicit successor choices include a Sandbox save and clearing an assignment.
They remain indexed through an empty ready collection, recovery dismissal and
duplicate old outcomes. Late old progress is refused. Subsequent not-sent facts,
representing withdrawal before worker entry, settle those original successors
without erasing either generation's uncertain/refused input or receipts. Existing
full-queue, cancellation, revision/recovery and finite-round scenarios read the
opaque histories through their history projection. No wording, row-order,
snapshot-output or PTY test is added.

All assertions are authored but unexecuted. The compound scenario uses production
state/protocol functions and synthetic publications; it does not run the actual
HTTP workers or TUI dispatcher. Parsing and diff/changelog checks establish no
typing, executed behavior, current-head independent approval, merge, installed
binary, visible UI, Loading resolution or matched Before/After speed. Future
matched measurements must retain failed, cancelled, interrupted and unfinished
samples instead of reporting only successful outcomes.
