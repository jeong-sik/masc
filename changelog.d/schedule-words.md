### Changed

- The TUI Schedules screen says how often a schedule wakes in the screen's
  language (`매 5m` / `every 5m`, `한 번` / `once`, `매일 23:55` on the
  operator's clock) instead of the wire summary (`every 300s`, `one_shot`),
  and its detail draws every moment on the operator's clock (`11-18 01:24`)
  instead of the wire text (`2026-11-17T16:24:45Z`). A set interval of a day
  reads `1d` everywhere, the Overview's proactive interval included.
