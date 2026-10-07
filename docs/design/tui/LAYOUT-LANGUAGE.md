# MASC TUI layout language

The operator accepted the Keeper navigation treatment in #41527 and asked for
the same tone across the TUI. On 2026-10-07 the density choice was explicitly
“지금처럼 여유 있게”: keep the breathing room.

[Compare the seven main surfaces](layout-language-preview.html). The preview
uses sample data and browser layout; it is a design reference, not a capture
of a compiled TUI. Its page states the same boundary.

## One visual hierarchy

The surface strip locates the reader. A list chooses an object. The body reads
that object. Supporting facts belong below or beside that reading; key hints
stay at the bottom. Each area answers one question.

- Use the terminal's own foreground for names and content. Recede separators,
  counts, metadata and hints through the existing theme tokens.
- Separate adjacent panes with one quiet edge. Full-screen content needs no
  enclosing box. Overlays can retain a frame so they remain recognisable.
- Only the row that owns keyboard focus gets a full reverse band. Keep a caret
  on an open selection when focus moves into its detail. NO_COLOR must retain
  both signals.
- Keep label columns fixed as selection moves. Fold long names in the middle
  when the identity's distinguishing end would otherwise be lost.
- Align the list title on the left and its count on the right. Preserve the
  difference between a loaded page and the whole collection: `3 of 9` is not `3`.
- Give headings, sections and the composer breathing room. A wider terminal
  gives the content more space; it is not a reason to add metrics or panels.
- On short viewports, reduce supplementary detail before losing selectable
  rows or actions. On narrow viewports, keep the screen's existing list/detail
  transition and the reader's place; do not invent another navigation model.

Status still comes from its typed reading. This treatment changes neither the
meaning of a pause nor a health observation. An unavailable read remains
unavailable. A quieter presentation must not conceal a failure or a decision
that actually needs the operator.

## The seven surfaces

| Surface | Main reading | Layout emphasis |
| --- | --- | --- |
| Dashboard | Decisions and a place to continue | A calm full-width body; no compulsory sidebar or metrics grid |
| Work | Selected Goal, its criterion and linked work | Compact index on the left; outcome and evidence in the body |
| Keepers | A Keeper and its conversation | Keeper rail, conversation, composer; selected and current target stay distinct |
| Usage | One account/window or history reading | Separate identity, measurement and observation time; no dashboard of unrelated totals |
| Board | A post and its replies | Quiet post index; title, author, body and discussion in reading order |
| Workspace | A repository, changed file or diff | Stable file/repository index; the source or diff gets the width |
| System | A setting and its effective value | Setting index; current/default/source near the value and its explanation |

These are presentation roles. Existing keyboard bindings, actor attribution,
mutation confirmation, data ownership and paging semantics remain authoritative.

## Implementation scope

`sidebar_line`, `sidebar_rule` and `sidebar_heading` in
`bin/masc_tui_render_prim.ml` are now shared by the Keeper rail and
`write_list_sidebar_selection`. The latter reaches the Tasks, Work, Schedules,
Task Review, Verdicts, Board, Approvals and Fusion detail indexes. The change
preserves their row budgets and label-folding width, while aligning labels,
moving counts right and replacing enclosing boxes with one edge.

The seven-screen preview records the wider direction. Bespoke Code, Resources,
Usage and System panels keep their own implementations in this change; this
document does not claim that every custom renderer has been converted. Their
follow-ups should use this hierarchy and their existing measured viewport
budgets, not a blanket removal of all borders.

The sidebar fold and Board holding-count tests retain semantic checks. Changed
source receives independent review and syntax checks. A compiled candidate and
the affected PTY scenarios are still required for runtime/layout evidence;
browser checks of the design preview do not provide that evidence.
