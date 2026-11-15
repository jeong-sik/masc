### Fixed

- TUI: colours drawn on a side pane (the Keeper roster beside the chat, a
  list index beside a detail, the Activity pane) are measured against the
  pane's own ground instead of the terminal page. A colour lifted to clear
  4.5:1 against the page by a hair fell under it one step off the page: ANSI
  cyan `(0,70,70)` on a black page lifts to `(68,126,125)`, 4.53:1 on the page
  and 3.59:1 on the `(30,30,30)` pane. On a truecolour terminal, status,
  next-action and receding text on those panes now clear the floor on every
  shipped scheme, dark and light. A 256-colour terminal still draws an
  estimated index (#47482). Colours on the page and in the chat header are
  computed as before (#47503, #PENDING).
