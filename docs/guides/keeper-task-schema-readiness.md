# Start with the current Task's declared Tool schemas

A current Task's exact Composition Skill already names the work's callable and
ordinary node Tools. The bundle supplies those schemas on the first request when
the same full Skill identity and content revision are executable on the frozen
turn surface. Its public `keeper_composition_run` control is supplied too, so a
task-specific upstream recipe can run without discovering that control first.
A declaration permitting deferred loading does not require another
model exchange to rediscover that existing selection.

| Case | As-Is | To-Be implementation |
|---|---|---|
| Current Task pins an available exact composition with deferred schemas | Model loads the callable or its node Tools before using them | First request carries those schemas |
| Reference belongs only to another held Task | Ordinary deferred loading | Ordinary deferred loading |
| Skill revision differs or a node is denied on the turn surface | Unavailable composition | No schema preload from that reference |
| Unrelated deferrable Tool or attached service | Ordinary deferred loading | Ordinary deferred loading |
| Schema is provided | No Skill activation | No Skill activation; actual execution retains the original recorder |

Selection comes from the immutable Task provenance in the turn activation frame.
Executable entries come from the same frozen capability surface as dispatch.
Matching uses the complete Skill reference, not a display-name prefix, source
path or another inventory scan. The original declarations are retained; initial
delivery is derived from the current work. No Task or Skill file is reread here,
and no activation, loader receipt or Tool execution is fabricated.

The source feature scenarios construct the actual public bundle with deferred
compositions, verify initial callable schemas, execute the selected inline Skill
and inspect its exact durable activation. They also cover another current Task,
absent current Task and a denied leaf. Syntax checks are not executed-test proof;
record the focused CI result and exact head separately.

For Before/After, freeze the same Task, Skill source, provider, model, prompt and
Tool behavior. Retain actual loader calls, model POSTs, serialized request bytes,
first useful action, completion and failed/unfinished attempts. Supplying more
schemas can increase the first request's bytes while eliminating a separate
loader exchange. Several Tool loads may already share one exchange, so a lower
Tool-call count alone does not establish fewer model POSTs or lower latency.
Synthetic protocol evidence and real-model cohort measurements remain distinct.

For an input artifact whose address is already known, put its physical read in
the recipe and connect the child parameter to that producer's output. Export the
selected input and required result together. This keeps the real output
dependency while allowing the model to submit one recipe. The successful
upstream scenario exercises this path; its expected IDs/digests validate actual
model-visible exports and never supply the answer.

## Share composition node field definitions

The public composition grammar still offers the same four node shapes:
ordinary Tool with optional `input`, ordinary Tool with fixed `args`, exact
Skill with `args`, and exact Skill with an upstream `input` template. Their
field schemas are now declared once on the enclosing closed object. Each
`oneOf` alternative retains its original required fields and explicitly forbids
the fields that its original closed object did not accept. A field can be shared
only when its definitions agree in every alternative.

| Schema component | As-Is | To-Be source representation |
|---|---|---|
| Node property definitions across four alternatives | 16 | 6 shared definitions |
| Full pinned Skill-reference definition in one node schema | 2 copies | 1 copy |
| Tagged input-template projection in one node schema | 2 copies | 1 copy |
| Recipe/prepare grammar and declared capabilities | Four original shapes | Same four shapes; canonical compiler and activation path retained |

This affects both prepare and the recipe embedded in run. The nonrecursive
provider projection remains in place. There is no new discovery call, reduced
Tool selection, skipped Skill read, fabricated activation or plan reuse here.
It reduces repeated schema structure; serialized request bytes and real-model
latency still require an actual matched request comparison.

The shared input contract also distinguishes the standard exclusion forms:
`not: {required: [a, b]}` forbids both keys together; `not: {anyOf:
[{required: [a]}, {required: [b]}]}` forbids either key. Previously the first
was flattened and the second was ignored by the top-level presence checker.
The public run schema can therefore reject `recipe` combined with `sha256` or
`resume_run_id` before dispatch while permitting prepared `sha256` plus its
original `resume_run_id`. Canonical plan/effect checks remain authoritative.
This is the presence checker's existing subset of JSON Schema; it does not
claim to validate every possible third-party predicate.

Feature scenarios cover the public run selector combinations, negated conjunction
semantics, node-shape refusals and actual compilation of Tool and exact Skill
arguments. Their `composition_schema` record reports the actual node/prepare/run
schema byte counts when executed; it is not a byte threshold or latency verdict.

The first useful action uses the `durable_tool_call_commit` boundary. The scoped
observer retains original physical execution, Task/trace/turn, native node and
parent identities after the durable append. Keeper owner handoffs explicitly
capture that observer, including its absence. Metadata-only sidecar records join
one-to-one to the actual Tool ledger; missing/ambiguous identity or failed sink
delivery makes coverage incomplete and the useful clock unknown. Native leaves
join the original SDK reply and canonical execution artifact rather than being
treated as SDK trajectory entries. When several successful input reads exist,
the earliest actual committed occurrence is retained.

This opt-in observer forces synchronous commits in its scope; ordinary callers
keep their existing append behavior. Compare both arms with the same observer.
Earlier SDK-callback clocks use a different boundary and cannot be pooled into
this timing distribution. The observation marks durable completion evidence,
not Tool start time.

The native preparation driver writes `<receipt>.stages.jsonl` and emits
`PREPARATION_STAGE` metadata before and after workspace/snapshot/owner setup,
Keeper registration, Task claim, bundle construction, original job start/result
collection, source admission and the actual Keeper cycle. Records carry epoch and
process-local monotonic clocks; job indices identify fixture occurrences. A
missing return record identifies an unfinished stage without inventing a timeout,
retry or completion. Cancellation preserves that unfinished evidence and propagates.
No model text, credential or request body is added to this journal.

These observer writes are synchronous evidence I/O. Matched timing comparisons
must use the same observer on both candidates and report its presence. The
synthetic scenario checks the first actual POST's Tool names and the physical
Tool-call ledger to establish that the Task's declared result Tool needed no
loader exchange; the configured real-model cohort still requires measurement.
