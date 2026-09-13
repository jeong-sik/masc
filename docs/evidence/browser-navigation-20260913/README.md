# Firefox followed-document observation — 2026-09-13

The final isolated Firefox trial executes the candidate's actual extension
message dispatcher, follow handler, readiness manager, and scene reader. Four
navigation cases return the expected visible content while an image response is
still blocked. A failed destination preserves its successful follow receipt and
returns the actual scene-read rejection. The harness performs no external wait
between follow and read and never repeats a follow.

Measured source: `b40259fc4baf9187936a0686301b937d76b7104e`.
The archived background is byte-identical to that commit. Only its final
`connect()` invocation is removed in the temporary extension; the fixture calls
`onHostMessage` with a reply sink and a synthetic 10-second command deadline.
The actual native host uses its existing 20-second deadline. This trial does
**not** measure the compiled MASC host, a Keeper composition, or a TUI session.
The earlier native/TUI continuity measurements are in
[the continuity evidence](../browser-continuity-20260913/README.md).

| Final case | Observed result |
| --- | --- |
| New document | `/first`, expected heading, `interactive` |
| Same-URL observed link | `/first`, new scene document ID, `interactive` |
| Server redirect | `/final`, expected heading, `interactive` |
| Fragment | `/final#hash`, same scene document ID, `interactive` |
| Failed destination | Follow succeeds; read rejects with Firefox's actual error |

All five owned cleanup stages succeeded. Browser and driver hashes, full replies,
native events, and the tested probe source are retained. The final probe takes
`--checkout`, `--source-commit`, `--driver`, `--browser`, and a new `--out` directory;
it loads the committed source via `git show` instead of reading a changing checkout.

## Why the first candidates were insufficient

These are selected diagnostic trials, not a claim that every experiment passed.

- `source-error-early-terminal`: the destination-error case initially ended on
  the old source's error before `/broken` failed. That case's early-success
  interpretation is withdrawn. The later `/broken` error in the raw trace also
  names the source native document ID, so source ID alone cannot classify errors.
- `first-complete-too-early`: after the real destination error, the first tab
  `complete` event still names the old URL. Injection fails. The new error
  document commits afterward. A first-complete rule is not a readiness proof.
- `commit-then-document-end`: wait for a new native document commit, then use the
  existing `document_end` injection. Visible content is read before slow-image
  completion; a committed error document returns a read rejection.
- `final-extension-dispatch`: the product candidate owns that barrier. The prior
  externally controlled event wait has been removed from the harness.

Production code does not classify Firefox error strings or tab loading text.
Native lifecycle IDs and MASC scene IDs remain separate. A navigation that never
commits or emits the matching fragment event may wait until the transport deadline.
No immediate-recovery, fastest-path, or latency improvement claim follows from
these isolated cases. CI-built native composition verification remains separate.

The source review also found a cancellation race during delayed preflight reads.
Commit `ba77291012` passes the AbortSignal through those reads and checks it before
registering observers and injecting effects. Four deferred-preflight regressions
cover deadline/disconnect at both tab lookup and frame lookup; the final Firefox
trial includes that source but does not simulate those cancellation races.

Run the offline evidence audit with `python3 docs/evidence/browser-navigation-20260913/audit.py`.

Primary references: [Mozilla's document-replacement injection issue](https://bugzilla.mozilla.org/show_bug.cgi?id=2047009),
[Firefox webNavigation events](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/webNavigation).
