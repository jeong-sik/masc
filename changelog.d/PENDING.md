### Fixed

- TUI: a full refresh that a navigation read joined no longer applies its
  older server identity when it finishes last. The navigation joins the
  refresh's ticket, so the ticket could not tell which collector read the
  identity later. When the navigation probe saw a replacement workspace B, or
  a withdrawal came after the refresh started, the refresh put its workspace A
  back. The latest collector dispatched, full or navigation, now owns the
  identity reading of its interval until a withdrawal. An older full bundle
  keeps its datasets only when its identity names the current workspace
  (#47424, #PENDING).
