### Fixed

- TUI: an image converter that exits 0 after writing bytes that are not a
  PNG no longer counts as a prepared frame. The next converter runs, and
  when none writes a PNG the remote preview fails with the received original
  and offers the recovery card instead of a draw refusal notice. Converted
  frames read back from either conversion cache are reused only when they
  are a PNG, so a frame an earlier TUI cached that way is converted again
  (#47628, #PENDING).
