# Composer metadata visibility and shared availability

Related PR: [#44155](https://github.com/jeong-sik/masc/pull/44155).

Source implementation only. Eight changed OCaml files are checked by parsing;
typing, test execution, native/PTY, CI, input and paint remain unverified.

## As-Is / To-Be

| Case | Before | After in source |
| --- | --- | --- |
| Startup Overview | Always asks the operator to choose a Keeper | Shows workspace/metadata read state until a normal observed list is available |
| Empty/unselected roster | Only says no Keeper is selected | Separate typed source observation distinguishes unobserved, failed, retrying and observed-empty |
| Failure then retry | Generic unread/loading reason | Retains the admitted failure while the original metadata read is pending |
| Created Keeper in an older read | Input is blocked, but explanation can say it left the roster | The same typed authority decision reports creation-metadata coverage pending |
| Work still pending/failed | Metadata already controls input independently | Work still cannot decide metadata status or release/revoke input |

## Authority and observation

`keeper_message_availability` returns a closed typed decision for a requested
Keeper. `keeper_available_for_new_message` is its boolean projection; the composer
uses the same decision for its target. The original successful predicate remains:
local persisted/declared row exists, workspace identity matches, local metadata
was read without an error, and any creation refresh demand is covered. Remote-only,
missing, unconfirmed and failure cases remain unavailable. Descriptions are produced
from typed states, not interpreted as scheduling or input instructions.

The independent `Composer.reading` observes workspace confirmation and required
local metadata status plus the current source's atomic pending facts. A retry does
not clear the last failure. An observed list with no pending read adds no note;
an observed empty list remains different from an unread or failed source. Work
facts never supply these fields. Source observations cannot authorize editing,
focus, voice or send; those continue to depend on the original target decision.

Overview calls the constant-time `source_reading` projection only. It does not
perform the full recipient/draft/attachment projection merely to show metadata
status. Cursor rendering returns Hidden immediately when unfocused, before
projecting any recipient/draft/attachments; otherwise the hidden cursor would
undo the source-only Overview path. Other composer rows retain their existing
full line projection. Their note is
appended after the existing prompt/draft; the editable prompt, draft window,
cursor calculation and one-row viewport budget are unchanged. Notes are escaped
through `Terminal_text.single_line` at each terminal consumer. Long notes can be
clipped by the existing viewport. Browser-owned input and approval notices keep
their existing precedence; there is no new stage timer, request or worker.

## Authored protocol scenarios, unexecuted

Existing multi-source scenarios in `test_tui_server_identity_refresh.ml` now pass
through the actual composer/send classifier. An older metadata observation can
include the created row while its required refresh remains uncovered: Enter must
not dispatch that draft. Only the owned covering metadata reply releases its
original recipient while Work stays pending. Another scenario retains an admitted
metadata failure, the original draft and send refusal across a retry, then permits
that same recipient after owned metadata recovery while the Work failure remains.
These are original source/coverage/draft/decision assertions. No display text,
layout, row order, snapshot, PTY, helper-mirror or invocation-count test is added.
The existing composer test factory only gains the required typed reading field;
its display assertions are not expanded. These scenarios use the existing source
protocol fixtures, not a real HTTP dispatch, filesystem-loader run or executed UI.

## Before/After evidence limits

No measured loading latency, percentile, memory improvement, usable-input time or
paint result is claimed. Source-stage display is observation, not successful Task
work. The shared decision keeps the original recipient lookup; the source-only
Overview projection adds constant-time field/atomic observation and note creation,
without a new recipient search, draft copy, request or worker. Normal full composer
projections add immutable observation allocation. Message input contents returns
the existing immutable string; do not count that getter as a draft copy. The
unfocused cursor removes an unused full projection, but focused line and cursor
still project and prepare their draft windows separately. Include projection, allocation,
escaping and logging costs in actual matched cohorts. Retain failure, cancellation,
withdrawal, missing observations and unfinished requests; never count absent phases
as zero or substitute send classification for an actual dispatched/painted result.

All six original goal axes remain open. This source change connects one remaining
visibility consumer and corrects an explanation; it does not prove the complete
Ask-to-Task/useful-work, Composition, recovery, startup or Before/After outcome.
