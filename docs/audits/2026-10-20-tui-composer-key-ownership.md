# Key preparation and bound composer recipient

Related PR: [#44177](https://github.com/jeong-sik/masc/pull/44177).

Source change only. Parent head: `972076e24603fb691bc6f7402577c1f8a81b9963`.
No typing, tests, TUI/PTY, actual dispatch, runtime measurement or deployment
was performed. Parsing is not behavior proof.

## As-Is / To-Be

`handle_composer_key` previously built the full renderable composer before
classifying every routed key. Ordinary focused edits and Esc do not need a
recipient or draft to choose their outcome; unrelated unfocused keys pass
straight to the surface. Nevertheless these paths resolved roster/availability,
read display-only source observations and counted attachments.

There was also a recipient mismatch in the source path. `of_state` followed
`selected_keeper`, while `send_operator_text` used `msg_target_keeper_name`.
`replace_keeper_rows` can remove the selected Keeper and move the list cursor to
another row without retargeting the focused draft. The displayed/authorized name
could then differ from the name used for dispatch or voice context. This is a
source-path finding, not an observed production delivery incident.

Rendering and key classification now share one target projection: a live composer
uses its existing bound message name; an idle row uses roster selection. Both
freshly apply the original typed availability decision. A missing bound Keeper
remains named but unavailable; another selected row cannot release the draft.

The pure key classifier asks for target/draft only in branches that need them.
Focus, send and voice actions carry the resolved Keeper name; the caller passes
that name to the actual open/send/voice operation. No frame data, memoized
availability or resolved action is reused for a later key.

| Source path per routed key | Before | After |
| --- | --- | --- |
| Ordinary focused edit, Esc, unrelated idle key | Full composer and target preparation | No target/draft/display-observation preparation |
| Focus or voice key | Full composer | One current target read; no draft/display preparation |
| Enter with available target | Full composer, then draft check | One target read, then original whitespace check |
| Enter without available target | Full composer | One target read; no draft read |
| Removed bound Keeper, another roster row ready | Cursor can advertise the other name | Bound name stays unavailable; send/voice remain refused |
| Owned metadata restores bound Keeper at another index | Cursor and dispatch names can differ | Same bound name supplies rendering, decision and operation |

All key paths now perform zero full renderable-composer projections. These are
source-path facts, not executed invocation-count tests or measured latency
percentages. Message contents was already an O(1) getter. Callback/closure/action
allocations and real target availability work remain; measure total input cost
before making a speed claim. The synthetic voice draft `"x"` is removed: the
voice branches directly require a reachable typed target.

## Original contracts retained

The outer workspace/Overview/browser/modal/text-field ownership guards remain.
The same actual key bindings still choose focus, release, edit, send and voice.
Send still requires a reachable current target and nonblank draft; creation
coverage, source failure, workspace and local-origin checks remain in the original
availability authority. Existing recovered-paste, voice resource, queue/drain and
message submission paths retain their guards. Metadata observations never grant
input. The focused target correction intentionally aligns the label/decision with
the existing draft owner instead of following a moved navigation cursor.

## Authored protocol coverage, unexecuted

The existing independent Work/metadata failure scenario now invokes the real
state-to-key classifier. After metadata retry/recovery, an owned metadata read
removes the bound Keeper, leaving another selected row. The original draft and
bound name persist; send and voice are refused. A later owned read restores the
original Keeper at another index while Work remains failed. Actions must carry
the original name although navigation still selects the other row. Existing
creation-coverage checks use the same production key projection.

Existing pure key tests only adapt to the callback signature and recipient-bearing
actions; one existing focus fixture records the explicit bound name. No new
display/layout/row-order/snapshot/PTY/helper-mirror/invocation-count tests are added.
The scenario does not execute the main loop, HTTP send or microphone.

Actual matched Before/After must include whole input/frame/source costs, original
recipient and draft ownership, workspace/cache/resources/logging, and all failed,
cancelled, interrupted and unfinished samples. All six original goal axes remain
open; this source implementation does not establish useful Task work or paint.
