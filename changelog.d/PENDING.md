### Fixed

- TUI: a Plugins result value whose key or label leaves it no room is no
  longer cut off. A row is cut at the pane width, so a lead as wide as the
  row, or a character wider than the cells beside the lead, dropped the
  value whole. When any piece of the value cannot fit beside its lead, the
  lead now takes its own row and the value hangs one outline level under
  the lead's indent, so a nested key keeps its depth (#51036, #PENDING).
