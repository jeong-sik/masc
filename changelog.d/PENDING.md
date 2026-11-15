### Fixed

- The TUI Planning list no longer draws an Executing or Verifying Goal whose
  due date has passed like one due later. Its row, the preview and the
  detail's Due field say `past due` (`기한 지남`), judged against 23:59:59 UTC
  of the due day, and a due date that cannot be read says `unreadable due
  date` instead of passing for no date. A Goal waiting for confirmation,
  paused, blocked, completed or dropped carries neither. Passing a due date
  closes no Goal and notifies no one (#39571, #PENDING).
