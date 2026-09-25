### Added

- The TUI Keeper runtime picker (Keepers, `U`) can now be narrowed by typing:
  `/` opens a filter over the drawn kind, target and route of every declared
  lane and runtime, Backspace edits it, and Esc drops the filter before a
  second Esc closes the picker. The count line shows the filter and `N of M`,
  and a filter that matches nothing says so instead of "loading". PgUp/PgDn
  move a page and Home/End jump to the ends. While the filter is open, `d`,
  `j`/`k`, the quit key and a paste go into the filter. The picker moves onto
  the shared `Masc_tui_pick_list`, which gains a `Follows_cursor` window for
  screen-high pickers (#38814).
