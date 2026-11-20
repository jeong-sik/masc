# MASC TUI layout language

The operator accepted the Keeper navigation treatment in #41527 and asked for
the same tone across the TUI.

[Compare the seven main surfaces](layout-language-preview.html). The preview
uses sample data and browser layout; it is a design reference, not a capture
of a compiled TUI. Its page states the same boundary.

## One visual hierarchy

The surface strip locates the reader. A list chooses an object. The body reads
that object. Supporting facts belong below or beside that reading; key hints
stay at the bottom. Each area answers one question.

- Use the terminal's own foreground for names and content. Recede separators,
  counts, metadata and hints through the existing theme tokens.
- Dashboard and plan usage can use cards to group related readings. Card
  edges can carry labels and status, leaving the body for the readings. Keep
  overlays distinguishable from the underlying content.
- Only the row that owns keyboard focus gets a full selection band. With a
  known palette it is a quiet neutral tint; without colours or a usable palette
  it uses reverse video. Keep a caret on the open selection in both modes.
- Keep label columns fixed as selection moves. Fold long names in the middle
  when the identity's distinguishing end would otherwise be lost.
- Align the list title on the left and its count on the right. Preserve the
  difference between a loaded page and the whole collection: `3 of 9` is not `3`.
- A wider terminal gives the content more space. Every surface, Dashboard
  included, starts with
  the narrow Activity pane when the terminal is wide enough for it, so the right
  side of a wide terminal is not left empty. The pane shows the typed reading
  Activity already owns; it is not a place for new metrics.
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
| Dashboard | Decisions and a place to continue | Decisions first, then titled cards; a graph writes its scale at its top-left, its card's edges carry the title and counts, and no column of numbers sits beside it |
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

## Usage

Plan usage keeps account names and window labels readable when the terminal
narrows; a long label moves to its own row before the meter. Exceptionally large
list labels retain their ends where grapheme boundaries are known and mark
omissions, bounded by the viewport; the account chooser retains the full
selected account name. The bar and percentage describe the provider's last
report, and `other use` identifies
windows that do not block model calls without relying on colour alone. A
window that blocks model calls when full is a declared limit: each filled cell
takes the colour of its position, success near zero, warning in the middle and
danger near the limit. Other-use windows do not block calls, so their bars keep
the receding token. The percentage still states the value.

Keeper usage keeps the recorded amount, reporting coverage and comparison bar
together when space allows. Each metric's bar is relative to its largest
complete reading, not to a quota, so it keeps the foreground colour. Missing
and partial readings remain explicit.
Other-use windows use the terminal-aware receding token rather than forcing dim
text. These choices follow the [GitHub CLI accessibility guidance](https://primer.style/accessibility/foundations/cli-accessibility/)
and [Shopify CLI colour guidance](https://shopify.github.io/cli/cli-kit/ui-kit/guidelines.html).

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

Dashboard begins with decisions and continuation destinations. Opening notices
and the last decision receipt stay ahead of the actions they affect; passive
health, completed-work and Candle summaries follow using spare rows. The same
typed selection and cursor window determine which requests remain visible.
Candle uses either full rows or one compact reading, without repeating both.

Work uses the same wrapped Goal/Backlog summary rows at every width. When the
width holds the list beside its preview, they are two cards; Work adds no card
that holds only statistics. The baseline/current snapshot timestamps
and change since baseline remain together; they are measured source times,
distinct from the wall clock removed from Dashboard, Work and Task titles.

`sidebar_line`, `sidebar_rule` and `sidebar_heading` in
`bin/masc_tui_render_prim.ml` are now shared by the Keeper rail and
`write_list_sidebar_selection`. The latter reaches the Tasks, Work, Schedules,
Task Review, Verdicts, Board, Approvals and Fusion detail indexes. The change
preserves their row budgets and label-folding width, while aligning labels and
moving counts right. A list and its detail can use separate cards when the
viewport has room.

The seven-screen preview records the wider direction. Bespoke Code, Resources,
Usage and System panels keep their own implementations in this change; this
document does not claim that every custom renderer has been converted. Their
follow-ups should use this hierarchy and their existing measured viewport
budgets, not a blanket removal of all borders.

The sidebar fold and Board holding-count tests retain semantic checks. Changed
source receives independent review and syntax checks. A compiled candidate is
still required for runtime evidence; browser checks of the design preview do not
provide that evidence.
