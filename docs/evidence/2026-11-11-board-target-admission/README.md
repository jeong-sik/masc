# Canonical parent admission for votes and reactions

A deletion can durably remove a post before it removes every child and before
all other stores refresh their models. Previously, a stale store could authorize
a new vote or reaction using its cached post/comment while its own leaf ledger
remained current. A duplicate vote could also return before validating the parent.
This is a source counterexample; no installed incident or backend reproduction
was executed for this change.

## Source and stack

- Base: `0e9718ca67e6132531614d5133cd836a2dc7aabc`.
- Production source: `2b2d43780e36b43ff65579713baf68eafadfd638`.
- Case source: `a97dc61c76b6ecf425822ea2021627213a636152`.
- Native Stack #51164: #51162 then #51163; target main, integrate whole through top.

`manifest.json` records the exact source paths and hashes. Later evidence and
changelog commits do not change the captured ML/MLI inputs. The complete stack
was rebased with `gh stack rebase`, retaining main's explicit reader in the TTL
helper and its exhaustive policy-test error match. Unrelated workflow/browser
changes are inherited main content.

## Resulting behavior

The private target-admission capture decodes complete canonical Posts and, for
comment targets, Comments in physical row order. It checks the actual request
reader and agreement of cached authority/routing fields. The actor used in the
vote/reaction record is a separate input. Direct store interfaces now require an
explicit reader; request callers pass their reader and existing trusted fixtures
pass Operator explicitly.

Writes hold Posts, optional Comments, then the actual Votes/Reactions scope.
Exact snapshot and workspace observations are retained through leaf IO. A parent
refusal precedes leaf IO and reaches its actual source owner. The duplicate-vote
path uses read-only parent and Votes guards instead of inventing a write receipt.
The reaction result carries the admitted parent ID to Dispatch notification and
visibility lookup.

A known leaf write publishes its receipt/model before reserved parent cleanup
propagates. A genuinely unknown leaf write retains its original before/intended
evidence and existing no-replay state. Leaf diagnostics and outer cleanup remain
distinct. Existing closed-post and posting-policy behavior is preserved; retained
orphans remain readable under their own source contracts.

## Evidence and limits

`validation.json` and `manifest.json` are unchanged copies of local captures.
All 42 changed ML/MLI inputs have successful parse-only receipts with OCaml
5.5.1; the repository target is 5.5.2. Forty exact-source receipts were reused,
and target admission plus the rebased TTL file were parsed again. Parsing does
not check types, warning exhaustiveness, dependencies or linking.

Whitespace checking passed. Static Dune-source inspection found 947 active
includes, no missing or duplicate include, and the new suite included once.
Dune was not executed. Sixteen existing fixture files contain 91 explicit trusted
reader ports; the TTL large-thread fixture now persists all retained comments
before performing actual canonical-target interactions.

The ten authored, unexecuted cases cover:

1. Four new mutation kinds after a real interrupted deletion prefix.
2. The same parent check before duplicate post/comment votes.
3. Reader/actor separation, Direct readership, aliases and restart retention.
4. Existing closed-post, posting-policy and unavailable-Policy behavior.
5. A changed Comments dependency, its actual owner and refusal before leaf IO.
6. A known vote surviving parent cleanup failure.
7. A known reaction surviving parent cleanup failure.
8. A duplicate validating a changed Votes source.
9. A real reaction unknown-write fault retaining evidence without replay.
10. A source-only Posts settlement refusing an incompatible old model.

`source-reviews.json` records two independent local readers and their source
scopes. Both initially missed an omitted `Recipient_lookup_failed` constructor
in a new forwarding match. The author found it by comparing the actual error
MLI with a main change, explicitly added it, and requested delta re-review. This
was a source correction, not a compiler failure or executed red/green result.

There is no OCaml typing/warning/build result, backend execution, new frontend or
browser execution, CI, installation or deployment evidence for this unit. Local
source verdicts do not constitute formal GitHub approval or integration proof.

## Remaining issue scope

Root #26378 remains open. Its other remaining questions are whether cleanup can
act after selection conditions change, whether the public Posts source-only
settlement API has actual product consumers, and backend failure/multiwriter/
restart execution. Each requires its own evidence and usage-based disposition.
Original #26415 waits behind that root.
