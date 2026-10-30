# Ready file resources inside mixed ordinary compositions

Source comparison base: `50ddbdefdd97cb1127f17b671e8b10e7a483dc3b` (#43791).
Source boundaries only; no executed overlap, runtime or speed measurement.

## As-Is / To-Be

The ready-file factory previously required only canonical Read/Edit/Write
producers and pure compiled child argument validation. One ordinary lookup in
the same inline plan made the entire factory return no ready plan. Disjoint file
mutations then lost producer-owned resource scheduling along with the lookup.
The aggregate factory for fully resolved outer named calls is separate.

The ready factory now admits ordinary Serial/Concurrent leaves alongside its
supported file producers. It still requires at least one file mutation and the
original Keeper, Task, trace and turn source. Opaque leaves keep their original
handler, input and execution mode. Only the original filesystem producer can
prepare and consume an actual file capability. An unknown footprint supplies an
ordering barrier rather than a guessed resource identity.

| Source boundary | Before | After |
| --- | --- | --- |
| One ordinary lookup plus two supported disjoint writes | Ready plan excluded | Mixed ready plan eligible |
| File-resource candidates within that plan | 0 | 2 |
| Original ordinary Serial/Concurrent contracts | Ordinary handlers | Same handlers and modes |
| Independent file leaves | Original ordinary schedule | Actual producer resource ordering |
| Concurrent lookup failure with Continue_independent | Original ordinary schedule | Wait for settlement; independent files remain eligible |
| Failed real file/data dependency or original Serial chain | Success dependency | Success dependency retained |
| Fail_fast at an observed failed barrier | Existing policy | Later effects blocked |
| Outer aggregate scope for mixed ordinary/file calls | Serial envelope | Same Serial envelope |
| Terminal/native async targets and async file replay | Existing admission | Existing admission retained |

Candidate counts describe source eligibility, not executed batches, saved
milliseconds, input readiness or provider roundtrips. The mixed path adds
classification, capability preparation and promise waits in cases previously
excluded. Their cost and net benefit remain unmeasured.

## Ordering, preparation and failure ownership

The closed ordering type distinguishes `No_order`, `Wait_for_settlement` and
`Require_success`. Real file conflicts and original Serial-to-Serial chains use
the last kind. Explicit plan and input dependencies retain their original
failure checks. Ordering-only barriers wait under Continue_independent without
pretending the opaque node produced the file or required data. Under Fail_fast,
an observed failed/skipped barrier still stops a later effect. Observed tickets
remain part of the existing failure-order comparison.

Opaque predecessors can change physical directory bindings. The original plan
therefore supplies an immutable index of opaque predecessors to await before
preparing later files, rather than preparing stale paths and waiting only before
dispatch. Concurrent ordinary leaves and prepared file reads retain their
sharing. File-only plans have an empty opaque-preparation index. A preparation
failure retains the original exclusive file handler and conservative ordering
against other file effects.

Binding publication and settlement waits follow the same stable topological
order. Original source, frozen descriptor authority, validated inputs, Gate
checks, physical leaf receipts, activation scope, cancellation and switch-owned
capability release stay with the existing producers. A mixed call does not
transfer an aggregate unknown footprint to the outer SDK. Whole-plan outer
aggregate eligibility remains file-only; native async ownership and durable
file-mutation replay permission are not widened.

## Authored evidence and limits

Five compound scenarios are authored but unexecuted. One uses the actual frozen
public bundle and inline recipe with `keeper_tools_list` and two real Write
handlers. An authorization rendezvous checks disjoint-file overlap without an
elapsed-time threshold, alongside output bytes, Task/trace receipts and Gate
aggregation. Four use the real Keeper executor adapter, frozen authority and
filesystem consumers: a concurrent lookup admission refusal under each branch
policy, an original Serial admission refusal, and replacement of file parents
before an opaque node publishes its settlement. The refusal is injected before
handler dispatch; the directory replacement is an external fixture mutation.
Neither is presented as a naturally occurring production failure. The Serial
fixture never dispatches its memory mutation.

Those cases retain the refused node's actual failed result and the original
physical files. The replacement case checks that new writes target current
parents while the retired parents keep their original bytes. They do not use a
real provider or native TUI. Parser and diff/changelog checks do not prove
typing, assertions, overlap, cancellation, independent approval, merge,
installation, UI visibility or speed. No local tests, Dune build or CI run is
performed. Later matched Before/After evidence must include the added
preparation cost and retain failed, cancelled, interrupted and unfinished
samples.
