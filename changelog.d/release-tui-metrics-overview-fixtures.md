### Fixed

- Retain Gate snapshot observations across transient errors in TUI metrics to prevent stale readings from collapsing into unread failures.
- Align Dashboard unread briefing fixture assertions with joined source note formatting.
- Align TUI tools request identity test harness with generation guard semantics by replacing artificial async observation expectations on stale responses with transmission-flushed completion barriers.
