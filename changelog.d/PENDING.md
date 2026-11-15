### Fixed

- Two rare Keeper memory writes now announce the Keeper's memory health row.
  A commit whose snapshot was durably replaced but whose journal did not
  finalize, because the journal line or the pending publication receipt after
  it failed, kept its receipt for the next recovery and sent no commit
  notification, so no reader was told and the row from before the write stayed
  on screen until another write announced the Keeper. The writer now announces
  the Keeper once its locks unwind. A writer that settles a removal receipt
  left beside its committed target appends the removal line the journal
  lacked; that line now announces the Keeper as it is written, since the
  writer can still fail before it commits (#52204, #PENDING).
