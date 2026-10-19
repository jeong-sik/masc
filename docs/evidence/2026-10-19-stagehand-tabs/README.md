# Owned Chrome tab and history evidence — 2026-10-19

The candidate's actual BrowserAction parser, Lane domain, Stagehand executor and
wire drove isolated Chromium with a fresh profile through the installed
Stagehand 4.1 runtime. The standalone bridge supplies an unchanged JSON callback
transport. This is not a full MASC server build or an installed binary check.

- Native creation returned a tab ID and its observed page URL/title.
- Native back and forward visited the prepared history entries.
- Native reload changed the page's generated document token.
- Confirmed close removed the tab; its retired ID rejected reload without a call.
- The next page received a larger ID.
- A real refused local port exposed a browser error page despite the runtime's
  successful navigation reply. The candidate returned a failed partial-effect
  receipt with `created:true`, owning `lane:stagehand`, and the created `tabId`.
  Exactly one creation and navigation occurred. Both the healthy sibling and
  created error-page tab remained observable on the same owned browser.

[Structured observations](chrome-result.json), [final healthy page](chrome-native-tabs.png),
and [source hashes](source-manifest.json) retain this execution boundary.

Separate actual-source protocol tests cover typed rejected, lost and known-unsent
navigation, unknown creation without an invented ID, metadata failure, malformed
close receipt without ID retirement, unsupported/frame actions before dispatch,
and monotonic IDs. The persisted production-tool test exercises actual
`Action.parse`, Lane admission, candidate Executor, action adapter and Tool_result:
partial phase, failed data and model-facing raw output retain the same recovery
receipt. Its standalone execution uses opaque unchanged output-content types and
unreached diagnostic/input-error doubles; no full router build is claimed.

No model call, synthetic DOM navigation, local Dune/full build, CI run,
installation, production restart, or live TUI validation is claimed. Frames,
dialogs, uploads, and other Stagehand BrowserAct actions remain unsupported.
