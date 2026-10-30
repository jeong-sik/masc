# Browser Lane server endpoint probe

Synthetic channel page, not Slack. The actual CI-built macOS ARM64 MASC server
(commit `50290c8521e6e8697c6923d8873ee75ac5d1e642`, executable SHA-256
`d349026e84be9e33424a6f0085e9767d20f35050717221d0af39688e08c54daa`)
ran in an isolated base directory on loopback with Gecko WebDriver and Firefox.
This candidate predates the fullscreen geometry and `v` key fixes in #34757.

`responses.json` contains the actual authenticated Browser Lane HTTP responses.
It contains synthetic page content only; screenshot bytes are stored separately.

- Region enumeration identified the channel navigation and message regions.
- Scoped reading excluded the channel sidebar and clipped messages.
- Clicking the observed thread reference succeeded. Its immediate receipt still
  had the previous URL; a later scene observation confirmed `#thread`.
- Screenshot capture returned the same page and viewport identity.
- `scroll_at` targeted the message pane. The immediate scene still showed the
  earlier messages; the subsequent scene showed Deployment follow-up and Older
  discussion. An action receipt alone therefore does not establish paint completion.

This proves compiled server-to-browser behavior. It does not prove TUI rendering,
real Slack performance, live extension activation, or a deployed release.
