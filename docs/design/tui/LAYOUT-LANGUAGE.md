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
- Only the row that owns keyboard focus gets a full selection band. With a
  known palette it is a quiet neutral tint; without colours or a usable palette
  it uses reverse video. Keep a caret on the open selection in both modes.
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

## Moving from the composer

The Keeper list starts closed. In chat, an empty composer with its cursor at
zero gives `Left` to the list. A nonempty draft keeps `Left` for editing, even
at its start. `Right`/`Esc` return focus to the composer; opening a Keeper also
closes the transient list. `Ctrl-B` remains the explicit pinning control and
`Ctrl-G` switches Keepers while keeping their drafts. Dashboard opens the
Keeper list with `Left` directly.

Input, paste and deletion operate at the cursor. Unicode grapheme boundaries
keep combined emoji and accents together. The composer viewport follows that
cursor horizontally and across newline-separated rows.

The preview starts in chat with a real editable field. It follows the same
empty-input boundary, supports per-Keeper drafts, and starts with the list
closed. Its muted text and neutral selection band demonstrate the quieter
palette direction. Native rendering retains the terminal foreground for text;
focused shared composers no longer colour the whole draft cyan, and known
terminal palettes supply the neutral sidebar band.

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

## Working footer

Working surfaces show their controls, action outcomes and actionable warnings.
They do not repeat other Keepers' activity or passive connection diagnostics at
the bottom of each screen. System's identity row contains the server version,
commit, port, age and workspace paths. Workspace/build disagreements and armed
or running operator actions remain global warnings.

The [consistency ledger](CONSISTENCY-PROGRESS.md) tracks the remaining surfaces
and separates source changes from observed executable behavior.

## Keeper list and Info

The roster leads with the Keeper name, followed by its typed health and turn
age. Its title keeps connection identity; search belongs to the working footer.
The repeated Health tally, wall clock, table rules and selected OPERATIONS
footer are removed. Fleet capacity, stale or incomplete observations and
configuration failures retain their own readings above the list.

Info owns lifecycle, turn phase, idle age and last outcome as separate Runtime
Stats fields, beside the existing runtime target. These fields follow the same
entry, refresh and retry lifecycle as their view. A failed refresh marks a
retained reading stale. Muted labels give the values the foreground; long labels
and values wrap into counted rows instead of being shortened to fit a cell.

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
