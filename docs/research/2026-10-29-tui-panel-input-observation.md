# TUI: information priority needs a matching input owner

This follows the [information-layer study](2026-10-28-tui-information-layers.md).
The [retained observations](../evidence/research/tui-panel-input-2026-10-29/README.md)
use an actual candidate TUI with synthetic data. The repaired candidate has
independent source review and focused pure-state checks. Final-code native
and UI validation have not been performed. Source review, compiled artifact and rendered behavior
are separate evidence.

## What the comparison established

| Surface | Actual observation on `0bf908e` | Design consequence |
| --- | --- | --- |
| Queue | 18/18 pending events visible at 120×36; 11/18 at 80×24; chat hidden | A full reader holds more rows, but loses conversation context. It is a useful detail mode, not proof of the best default placement. |
| Queue → Help → Queue | `?` opens Help; Esc returns | Keep the familiar parent/child action and return path. |
| Context | Paste changes a covered chat draft; `?` is offered but does not open Help | Display and input priority must use the same frame owner. |
| About | Hints-off footer offers `?`, which leaves About open | Key tables and actual dispatch need to agree, including hints off. |
| Agenda / Answering | Source dispatch could reach an asynchronous form first | Reuse the same owner contract; actual rendered confirmation remains unmeasured. |

At 80×24, the Queue capture spends five of its 17 body rows on read state,
an empty local-input count, inventory summary and two generic explanations.
The remaining 12 rows show the running item and 11 pending events. This is a
cell-budget observation at one state, not a readability or speed score.

## Information scores and placement

These are analyst priorities for a person managing a queue, not measured user
ratings. The existing rubric adds consequence (0–3), urgency (0–3), relevance
(0–2) and cost of a missed/misread fact (0–2). Scores guide prominence and
progressive detail; they do not grant permission or erase unknown states.

| Information | Score | Placement decision |
| --- | ---: | --- |
| Workspace mismatch; effect outcome unknown; pending operator decision | 10 | Persist near the active task. A new arrival does not silently take an editor's keys. |
| Selected item, available action and result | 9 | Keep together in the active panel. A later read failure must not replace an already observed effect. |
| Current running turn | 7 | Compact explanation of what queued input waits behind. |
| Other pending items | 6 | Navigable list; selection survives refresh by identity. |
| Future schedule; exact IDs before detail is requested | 3 | Summary or explicit detail; do not imply ordinary reorder controls affect its due time. |
| Repeated stable rules | 1 | Help/detail rather than repeated body rows when space is scarce. |

An ID becomes high priority when needed to distinguish two targets; a schedule
becomes urgent as its due time approaches. These are contextual priorities,
not constants added to product state.

## Keys and layers

Use `Ctrl-T` or `/queue` to open this Keeper's queue, arrows/`j/k` to select,
Enter to inspect, `?` for Help and Esc to return. Keep selection distinct from
changing order. Existing next/end actions affect supported queued messages;
event controls set urgency. Neither means interrupting the current turn.
Letter keys and `?` stay literal in search and text entry. Terminal chord and
physical Korean IME delivery still need observation on the operator's setup.

| Combination | Input and display contract |
| --- | --- |
| Queue + Help | Operator-opened Help is above Queue; returning restores its parent. |
| Context + Help or About + Help | Help covers its parent and consumes input; covered forms cannot take keys or paste. |
| Context + explicit `/` query | Query owns typeahead in the same workspace, Keeper and inspector generation. Enter/Esc ends it; another action waits for the next frame. |
| Read panel + late underlying model form | The displayed panel processes keys first. Paste cannot reach the covered form or composer. |
| Editor + newly arrived Play/approval | Arrival and input ownership are separate. Preserve the existing presented-owner checks; do not promote unseen decisions. |
| Resize / incomplete paste | Recovery keeps its input boundary. Explicit paste cancellation must be able to display its recovery instructions. |

This is a parent/child and ownership policy, not a set of numeric z-indexes.
Help is above About/Context when explicitly opened; independent account,
detail and Play owners keep their existing precedence. The Queue/Play race
retains its specialized presented-target checks.

## Implemented scope and remaining decision

[PR #46688](https://github.com/jeong-sik/masc/pull/46688) extends the existing
immutable presented-frame snapshot. It adds no mutable state field. One
canonical About/Context binding table supplies Help and footer guidance.
Displayed panel dispatch precedes covered form handlers; the original effect
owners remain at the edges. An explicit search grant preserves typeahead and
requires a real presentation even when cancel returns to identical pixels.

Focused checks inspect immutable state and input decisions, including changed
workspace/inspector/Keeper, query termination and post-output pending input.
They do not assert screen text or row layout. The native build of earlier
candidate `c48c88d` failed on interface/identifier errors; those were fixed.
Its failure is not runtime proof of the new candidate. Current validation and
exact source are recorded in the PR.

The placement hypothesis remains: preserve chat with a side pane when both
documents have enough cells, try a bottom sheet at smaller widths, and retain
a full reader for long detail. The present measurements do not choose a
winning responsive layout. A fair next comparison must use the same source,
data, selection and viewport, measure visible selected action/result and chat
context, then observe repeated tasks and mistaken actions. A browser sketch
alone cannot establish the best TUI layout. No claim of faster operation,
better user readability or production deployment follows from this study.
