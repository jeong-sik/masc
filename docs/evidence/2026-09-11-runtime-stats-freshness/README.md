# Overview runtime statistics freshness

The server already returns `cache.state`, `age_s`, and an optional refresh error. The Overview decoder discarded them and displayed only the new response receipt time. A response containing a 2,228-second-old aggregate therefore looked recently read without showing its stale state.

The UI now distinguishes fresh, refreshing an older aggregate, first aggregation, and unavailable freshness metadata. Age is explicitly the aggregate age at response time; no exact observation-window end is invented. Refresh errors remain visible while the last successfully read values are displayed.

Validation: `tsc --noEmit` and all 14 runtime statistics component tests passed. Tests exercise the real API decoder through a stale response, manual refresh, and fresh response; independent source review found no blocker.

Browser `before` and `after` replay the exact same previously captured runtime response. `live` uses the actual unchanged isolated backend, which returned a stale response with age 636.063596 seconds; the new UI displayed 636.1 seconds and refreshing state. All three captures had zero page errors. These are Vite source previews, not installed-dashboard deployment evidence.
