# Work, Workspace and System panels

The implementation builds on measured viewport budgets. It is not a claim of
installed or production behavior until current-head executable evidence exists.

References inspected on 2026-09-30:

- [btop](https://github.com/aristocratos/btop): named panels separate observations.
- [lazygit configuration](https://github.com/jesseduffield/lazygit/blob/master/docs/Config.md): selected rows and focused borders make keyboard context visible.
- [Textual layout guide](https://textual.textualize.io/how-to/design-a-layout/): nested layouts and grids make related content read together.

Work pairs the Goal outcome summary and Task backlog only when their widths
and rows leave the selected Goal and verdict visible. Goal completion counts
remain separate from Task counts. Small frames retain the existing summary.

Workspace pairs its repository list and selected context where named table
columns and detail text fit; narrow frames stack the panels. Cursor and page
movement use the same selected-context geometry as the renderer. Failed reads
remain explicit, server-resolved paths remain authoritative, and repository
failure reasons lead the detail. Omitted context is marked rather than silently
shown as complete.

System groups the selected setting's Current, Default, override state, type,
bounds and description. Friendly values preserve the existing on/off vocabulary.
Inline editors retain their own keys and compact layout. Decoded values are
sanitized before drawing.

`test_tui_surface_studio_pty` drives keyboard navigation, selected repository,
small viewports, edit/cancel and NO_COLOR under controlled HTTP fixtures. The
manual targeted Test workflow captures original ANSI, compares all nonempty
xterm text, exact cell geometry and full pixel bounds, then publishes PNGs with
source SHA, binary SHA-256 and producing run. Fixture evidence does not prove
production behavior.
