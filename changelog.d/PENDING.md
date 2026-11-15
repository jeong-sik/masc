### Fixed

- A Keeper's cached memory health row is now emptied by every write that
  announces it. A turn record write, a vision error and an unread ledger
  archive, among others, announced the Keeper while its cached row stayed, so
  the read the announcement woke answered the row from before the write. The
  memory health broadcast now empties the row, then the fleet answer, and
  only then announces. The store hooks that already emptied the row stay; a
  write both reach reloads the row once (#52018, #PENDING).
