### Fixed

- Entering a Keeper chat in the TUI reads its history once. The place that
  opens the chat starts the read. The surface-needs delta starts it for the
  ways in that start none, and it now skips an entry that a read started
  while the chat was on screen, even when that read has already landed. Before,
  the delta checked only for a read in flight. An opening made while the TUI
  applied server answers (the startup chat, a newly created Keeper) could
  therefore read the history, the memory journal and the open operations'
  journals a second time (#42012, #PENDING).
