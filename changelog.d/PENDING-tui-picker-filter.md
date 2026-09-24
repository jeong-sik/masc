### Added

- The TUI runtime candidate picker (Runtime lanes reading and Lanes surface)
  can now be narrowed by typing: `/` opens a filter over the drawn runtime
  id, provider and model, Backspace edits it, and Esc drops the filter before
  a second Esc closes the picker. The header shows the filter and `N of M`.
  PgUp/PgDn move a page, Home/End jump to the ends, and the arrow keys move
  the picker (before, only `j`/`k` did, and the arrows moved the list hidden
  under it). The cursor, filter and visible window live in one shared module,
  `Masc_tui_pick_list`, so the other pickers can move onto it.
