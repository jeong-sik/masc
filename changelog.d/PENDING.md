### Fixed

- A preset name whose save went unanswered is no longer guarded for the rest
  of the TUI session after a later save of the same name is confirmed. The
  overwrite warning follows the newest receipt that wrote or may have written
  the name; a later save that was refused or never sent keeps the warning, and
  only the receipt behind it reopens (#46746, #PENDING).

### Documentation

- The librarian durable message-floor RFC no longer lists a Memory change at
  publish time as open: section 3.8 points to the decision in 3.10, item 8.
  The layer tables stop saying L3, L3e and L4 have no caller and name the
  merged L3e, L4 and L5 pull requests (#46746, #PENDING).

### Internal

- The TUI queue peer reader's tests pin that the operation list's `state` tag
  and each operation's `state` accept only the server's `Queued` spelling;
  `queued` and `Paused` are refused. The reader is unchanged
  (#46746, #PENDING).
