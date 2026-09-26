# Fixed footer pin rules

## Observation

A five-second native sample on the existing optimized TUI artifact
`f69b7b40a379f3b3ff7fd8060b041d0315b15851` showed repeated footer classification
while scrolling the synthetic Info fixture. The raw stack is
`native-sample.txt`: `String.split_on_char` has 87 self samples, and some stacks
reach it through footer `key_atoms`. The footer also decomposed each of its
seven fixed pin strings for each inspected hint item, including repeat visits
while fitting a narrow row. This source work is independent of elapsed time.

These are investigation clues, not proof of a dominant bottleneck or predicted
speedup. Sampling perturbs execution. The profile altered the observer's detail
precondition checks to sustain the workload; it is not the unmodified benchmark
or a general regression proof. See `INTERPRETATION.md` for the CPU attribution
correction: child resource totals include the profiler and must not be reported
as TUI CPU. No claim about the earlier 25ms CI input is made.

`files.json` identifies the retained original profile files. The observation
and stdout are losslessly gzip-compressed; `gzip -dc observation.json.gz`
recovers the unchanged original receipt. All 24,006 observations are retained.
The profile predates this footer change and is not a before/after result.

## Change

The pin declarations now distinguish `Key_atom` from `Whole_key` directly.
`Esc`, `q`, and `Enter` match an atom in the rendered key; four compound rules
match their complete key spelling. Only the rendered key is split. This removes
all repeated splitting/counting of fixed pin rules without adding a cache,
retaining previous frames, or changing width and hint-drop policies.

ANSI removal, the first-colon key boundary, compound Escape and Enter keys,
and the exact spelling of approval pairs retain their existing behavior.
The existing verification-pair test now invokes the classification behavior
instead of inspecting the old string-list representation; its narrow-footer
behavior assertion remains.

## Verification boundary

Source parsing and whitespace checks pass. Independent adversarial and response
reviews found no semantic difference or missed caller after the type change.
Compiled footer/key tests and a controlled artifact comparison are still needed.
No local OCaml build, deployment, or measured improvement is claimed.
