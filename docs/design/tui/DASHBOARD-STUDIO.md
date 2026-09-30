# Dashboard Studio — terminal UI research and implementation

2026-09-30. Sources inspected live; observations describe those sources, not a
claim that one design represents every contemporary terminal application.

| Reference | Observed design | MASC application |
| --- | --- | --- |
| [Charm Lip Gloss v2](https://github.com/charmbracelet/lipgloss) | Bordered blocks, padding, horizontal composition, semantic styling, colour-profile fallbacks | Cell-measured cards, restrained status colour, explicit selected marker, native terminal palette |
| [btop](https://github.com/aristocratos/btop) | Separate resource panels, graphs beside current readings, selectable layouts | Measured Work trend beside current counts; information stays scoped to its source |
| [Textual layout](https://textual.textualize.io/guide/layout/) | Horizontal, vertical and grid composition with constrained dimensions | Two-column Dashboard on wide/tall terminals; compact focus on short/narrow terminals |
| [lazygit](https://github.com/jesseduffield/lazygit) | Keyboard-oriented panels with visible focus and contextual actions | j/k and arrows select cards, Enter opens their full existing surface |
| User-supplied Codex Usage screenshots | Summary/detail modes, readable alignment, periods and missing-data copy | Selected card expands in compact mode; full details stay in their domain surfaces |

## Product contract

Dashboard answers where the operator should look next. It does not turn all
runtime failures into approval requests. The attention card names its actual
Enter destination: pending or unread approval sources go to Approvals;
otherwise the operator inspects Keepers. Enter never approves, restarts or
changes runtime configuration.

Cards are ordered Needs you, Work, Goals, Keepers, Usage. Work opens its task
list; Goals opens its goal list. Selection is a typed section and survives
refreshes and resize. Tab keeps the established top-level navigation.

The wide layout contains two pairs of bordered cards and a Usage band, capped
at 160 cells and centred. Its minimum width comes from two readable 48-cell
panels and a two-cell gutter. Insufficient height switches to a compact layout
that preserves headings and summaries and expands the selected card. Extremely
short viewports switch to single-row cards and keep the selected destination
inside the visible window. Hidden
detail rows are counted and the complete source is reachable with Enter.

Quota-report coverage is not account utilization. Task counts and their UTC
trend are not Goal progress. Missing/unread/failed data retain the existing
source semantics. Runtime-blocker previews use the supplied cause field;
there is no substring classification of errors or synthetic grouping.

## Verification required

Current-head PR checks; targeted Linux PTY scenarios covering populated, empty,
unread and failed data, wide and compact frames, Korean text, colour and
NO_COLOR, keyboard navigation, refresh/resize selection, and return paths.
Screenshots must identify source SHA and whether they are CI fixture PTY,
installed binary or production. Existing user sessions stay undisturbed.

## Replaying CI frames

`test_tui_dashboard_studio_pty` records `STUDIO_CAPTURE` JSON with actual ANSI
frames. After a targeted run finishes, save its raw logs and the output of
`gh run view RUN --json headSha,status,conclusion,url,databaseId` locally.
Run `scripts/capture-dashboard-ci-frames.py --log LOG --run-info RUN_JSON
--expected-head SHA --out DIRECTORY` to replay those bytes in xterm and capture
PNGs. The resulting manifest records both the producing run and whether the
suite's PASS line exists; a captured frame alone is not a passing test.
