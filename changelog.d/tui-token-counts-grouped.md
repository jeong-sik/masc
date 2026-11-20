### Changed

- Token counts in a Keeper's context override, the Inspector's input scale
  and its configured context are grouped (`200,000 tokens`). A Keeper chat
  background task's usage reads `12,840 tokens · 3 tools · 6m55s reported`
  instead of `415000 ms`, and its states say `status not reported` and
  `end not reported` / `end reported` instead of `status unreported` and
  `terminal unobserved` / `terminal observed` (RFC tui-one-screen-grammar
  6.2–6.4).
