# Ask reader editor ownership: source comparison

Scope: the full reader's separate free-text editor branch in
`bin/masc_tui_render_prim.ml`, relative to parent source head
`495f6116e1a42fc89a6ebc249fb6b551a192f911` (#43818).
This is a source invariant correction; no runtime defect was reproduced.

## As-Is and To-Be

Every Ask can have a question named `q1`. An editor's immutable `ate_slot`
already holds both the original Ask ID and the original question ID. The
shared `draw_ask_question` branch checks both, but the full reader's separate
editor-only branch checked just the question ID. If selection and editor owner
disagree, that branch could associate the original text with another Ask's
same-named question. This statement describes the branch predicate; it does
not establish a reachable mismatch during a normal user session.

| Boundary | Before | After in source |
| --- | --- | --- |
| Full reader editor acceptance | Question ID matches | Original Ask ID and question ID both match |
| Shared question renderer acceptance | Both IDs match | Both IDs match |
| Different Ask with the same `q1` | Editor-only branch accepts | Editor-only branch rejects; shared renderer also rejects |
| Original Ask and question both match | Editor-only branch accepts | Same branch accepts |
| Editor data and save destination | Original immutable slot | Same original immutable slot |

The acceptance predicate has one identity component before and two after.
There is no new request, cache, timer, read policy or run-time configuration.
No timing, memory, CPU or failure-rate improvement is claimed.

## Normal flow and effect boundary

- `begin_ask_text_entry` creates the slot from the selected original row and
  question. While typing, printable keys edit that buffer before the answer
  navigation handler gets them.
- `apply_asks_load` normally reanchors the answering cursor by `aam_ask_id`.
  If that Ask disappears with confirmed workspace identity, it clears answer
  mode, draft and editor. An unavailable read retains the previous snapshot.
- `commit_ask_text_entry` finds the open row by the slot's Ask ID and applies
  `Ask.set_text` with the same slot. It does not borrow the current cursor's
  Ask. `set_text` rejects a draft belonging to another Ask.

Those protections already exist. This change makes the full reader obey the
same pair of identities even if upstream selection and editor ownership differ.
It neither retargets nor clears the original input/draft and adds no submission
authority. The existing non-editor rendering branch remains the fallback.
It does not solve every possible stale selection, hidden-editor or workspace
transition problem, and makes no claim that such a problem was observed.

## Evidence boundary

Read the editor's creation, typing, commit and clearing paths, snapshot cursor
reconciliation, and both rendering branches. Check OCaml syntax with parsing
only, plus the diff and changelog fragments. These checks do not prove typing
or rendered behavior. No wording, layout, row-order, snapshot, PTY or predicate
mirror tests are added. No local build, typecheck, test execution, CI, native
run, installation or restart is included. Actual input, paint, reachable
transition and matched Before/After latency evidence remain uncollected.
