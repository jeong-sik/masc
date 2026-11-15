### Fixed

- With nothing open, the wide pane of the Code and Resources split screens
  says what the list beside it holds. A failed list read is drawn there whole
  with `page_failed_note` under it, instead of only in the 32-cell list pane
  that cut the cause off its end; a failed refresh's reason appears beside
  the rows it kept. Code offers "(Enter opens the selected file)" only when
  the listing holds rows to select, and Resources' list says it is unread,
  not loading, when no inventory read is pending (#35894, #PENDING).
