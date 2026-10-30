# Write resources through the outer named Inline batch

Source comparison base: `69346c7d86da88655cca6ece4b2cf5a62851f2c6` (#43788).
Source boundaries only; no executed overlap, runtime or speed measurement.

## As-Is / To-Be

The owned Write producer, operation variant, scope transfer, current-input
consumer, aggregate cleanup and inner ready-file scheduler already existed.
However, aggregate eligibility required at least one Edit and allowed only
Read/Edit leaves. A fully resolved named Write-only or Read/Write Skill therefore
never reached the existing aggregate preparation path. Independent outer calls
kept the ordinary Serial envelope even when their real file resources were
disjoint. Ready binding inside one recipe did not supply outer batch ownership.

Eligibility now includes canonical Write alongside Edit with their original
ordinary Serial contracts; Read remains ordinary Concurrent. At least one
mutation and only those file producers are still required. The existing frozen
surface, original source, completion and causal-isolation checks remain. Once
all model inputs resolve and validate, the same aggregate factory prepares each
original Write and transfers the union of actual claims through the existing SDK
scoped-call interface. No resource identity or input is synthesized here.

| Source boundary | Before | After |
| --- | --- | --- |
| Write-only / Read+Write aggregate eligibility | Excluded | Eligible with existing source/input checks |
| Resource-bound candidates for two supported, disjoint named Write calls | 0 | 2 |
| Outer scheduler ownership | Ordinary Serial envelopes | Actual producer-owned aggregate claims |
| File effects, Gate, receipts and activation | Existing producers | Same producers |
| Async file mutation admission | Refused by replay contract | Still refused |
| Dynamic/unsupported aggregate | Ordinary path | Same ordinary path |

These count eligibility and candidate bindings, not executed batches, saved
milliseconds, first usable input or provider roundtrips. New aggregate binding
adds pre-dispatch directory/stat work and open capabilities in cases previously
excluded. Actual preparation cost versus overlap benefit remains unmeasured.

## Ownership and lifetime

An existing target keeps its producer's lexical/resolved entry and inode claims.
A missing target or directory keeps the actual physical parent/ancestor claims.
Directory aliases, hard-link/object ordering, missing-parent progression and
current-input revalidation all stay in the existing Write producer. Shared
resources still order; this is not blanket concurrency for writes.

The source must retain the original Keeper, Task, trace and keeper-turn context.
Only the original immutable plan and checked input can consume an acquired
operation. Aggregate scopes retain the switch-owned capabilities through
execution. Partial acquisition, unsupported resources and cancellation use the
existing cleanup for Write as well as Read/Edit. Preparing grants no Gate,
publication recovery or durable replay authority and creates no directories.
Terminal plans, native child submission/result targets, other effects and
missing/unisolatable source contexts retain their existing admission paths.

## Authored evidence and limits

Four unexecuted compound cases use real published Skill documents, the actual
frozen public bundle and outer SDK dispatch. Two disjoint named Write calls
rendezvous at the actual file authorization boundary, including an existing-file
case, a fully resolved Read/Write case and missing directories under disjoint
owned ancestors. They check bytes and original Task/trace, leaf receipts and Gate
aggregation. An alias/cancellation scenario checks physical alias ordering,
caller cancellation before write authorization, unchanged targets and fresh
invocations reacquiring both resources. Distinct Tool-use identities are used
for alias, cancelled and later calls. Existing Edit fixture publication is shared
without changing its source configuration or document content.

These cases have no clock/timeout assertion and remain authored, not executed.
They exercise actual filesystem and SDK paths when run, not a real provider or
native TUI. Parsing and diff/changelog checks do not prove typing, cancellation,
overlap, missing-parent behavior, independent approval, merge, installation,
visible UI or speed. No wording/layout/snapshot/PTY test or new local/CI run is
added. Later matched evidence must retain failed, cancelled, interrupted and
unfinished outcomes and include the added preparation cost.
