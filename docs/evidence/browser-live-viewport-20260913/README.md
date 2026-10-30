# Actual live Firefox viewport actions

Native fd441 server/TUI/host and the matching extension operated an owned headless
Firefox profile through live client ae865f36-42fa-4e0a-9489-f3139728025c.
Full source and binary SHA-256 provenance are retained in report.json, bundle.json
and candidate-source-proof.json. No normal browser profile or Slack was touched.

Actual TUI actions were click_at, scroll_at and scroll_at, all HTTP 200. The link
opened Details; the nested pane scrolled 120 pixels. An independent WebDriver
navigation in that same owned profile changed the document while the TUI remained
open. The old viewport was rejected with HTTP 400/page_url_changed, then the next
TUI scroll used the displayed new document and URL. No effects were retried.

Live drag was not attempted and is unsupported. This is not a trusted-drag proof.
There was no Keeper/model in this gesture run; live Keeper reading was a separate
experiment. Screenshot PNGs here are actual transmitted image payloads decoded
from native TUI Kitty-protocol placements, not text-screen replays. No assertion
of atomic screenshot alignment with another observation is made.

Run `python3 audit.py` from any directory. This offline audit verifies binary
identity, live client/tab/action routing, PNG bytes in PTY output, DOM effects,
stale refusal, new document binding and TUI/server/driver/profile/manifest cleanup.
The scripts preserve the actual capture procedure; they require the historical
owned runtime prerequisites and must not be mistaken for offline audit commands.
No credentials, runtime config or native-host manifest is included.
