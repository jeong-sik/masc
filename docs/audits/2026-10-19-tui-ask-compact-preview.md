# Keep a tall question identifiable in the compact Approvals panel

Source comparison base: `d1cd9758c92389424a563fce692ea983b8f43b80` (#43811).
This is source behavior and budget reasoning, not an observed terminal frame.

## As-Is / To-Be

The compact Ask panel fits complete pre-rendered question blocks. If the
selected question's prompt, choices or draft exceeds the remaining space, a
window starting at that question can fit zero blocks. The panel then emits only
a hidden-question count, even though there is room to identify the question.
Its hidden-count line is also emitted whenever the count is positive, including
when no content rows remain after the already drawn header.

The layout now distinguishes full questions from one compact selected preview,
and explicitly budgets the hidden-question notice. Normal full-question windows
keep their existing selection. When none fits, positive content space goes to
the selected preview first. It uses the existing compact-row reservation; this
does not add a Keeper runtime limit or change how much of the original question
can be read or answered.

| Boundary | Before | Source implementation |
| --- | --- | --- |
| Selected whole block cannot fit but content space exists | Zero question blocks | One selected preview |
| A single content row remains | Could show only hidden count | Original selected question row |
| No content rows remain | Hidden notice can still emit one row | No unbudgeted hidden notice |
| More preview space exists | No partial question representation | Complete original rendered rows plus full-reader hint |
| Hidden-question navigation hint in compact browsing | Named j/k, which changes questions only inside answer mode | Names the existing full-reader key a |
| Full prompt, choices and draft | Existing scrolling answer reader | Same complete original reader |
| Draft/answer mutation | Existing answer-mode actions | No new action or submission from preview |

These are source branch/row counts, not a measured visibility success rate,
paint/input latency or runtime Before/After cohort. A one-row preview has no
additional room for its own reader hint; the existing panel header still names
the answer-reader key. Other hidden questions remain in the original inventory
even when there is no room for a separate hidden-count row.

## Original data and bounded projection

The preview copies only complete newline-terminated rows from the same question
buffer already produced by the existing terminal-safe renderer. It does not
slice inside ANSI or UTF-8 sequences or create a separate shortened question
model. When another row is available, it uses one of the allocated preview rows
for the full-Ask reader hint. The same locally clamped question cursor controls
both the original caret and the layout window.

The layout accounts for the actual preview, hidden notice, context/context notice
and folded asks. A hidden notice requires its own available row; zero content
space cannot create one. This fixes that notice boundary, not every header or
surface budget elsewhere in Approvals.

The existing full answer reader and controller retain their original Ask and
question identities, complete prompt/choices, draft/free-text handling and
submission/read-authority decisions. Previewing does not open a draft, choose a
default, enter answering mode, submit an answer, issue a read or infer Task/Goal
completion. This layer changes neither the asynchronous POST/follow-up lifecycle
nor any timer, polling loop, runtime configuration or Keeper prompt.

Existing question blocks are still fully generated before selection. This
change does not establish render/preparation CPU reduction, allocation savings
or a Loading latency improvement. It adds a small prefix copy for a preview;
its runtime cost is unmeasured.

## Evidence and remaining scope

OCaml parsing-only covers the layout and Approvals renderer. Diff and changelog
checks cover source metadata. No tests are added for wording, row order, layout,
snapshot output or PTY frames. No build, typecheck, test execution, CI dispatch/
watch, native/model run, install/restart or measured frame accompanies the layer.
Source budget reasoning is not type, visible UI, input or speed verification.
The public key guide and TUI skill describe the read-only preview boundary.

Independent review of the current head is pending. The broader goal remains
active: original Ask/Task/useful work, exact frozen preparation, ordinary/nested/
dynamic/effectful resource continuity, held/shared-backend work, TUI readability/
visibility and matched actual observations retaining failed, cancelled,
interrupted and unfinished attempts need their own evidence.
