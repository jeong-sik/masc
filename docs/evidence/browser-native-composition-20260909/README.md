# Native MASC composition preview

Actual Skill Studio response from the isolated CI-built server at commit
`50290c8521e6e8697c6923d8873ee75ac5d1e642`. The exact Skill reference was obtained
from `/api/v1/skills`, then sent with the source text to
`/api/v1/skills/editor/preview`. Validation returned no diagnostics.

The registered profile is `composition`, with activation tool
`keeper_compose_browser-live-click-regions`. Its two batches bind BrowserInteract
click output to the BrowserRead region request through both data and ordering
edges. The reported eager body size is zero; source is loaded on demand.

This proves native discovery and validation in the candidate server. It is not
evidence of a production publication, Keeper invocation, or successful Slack
collection. The configured production collector targets dev-frontend; its
private content is not included here.
