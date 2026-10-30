# Browser action catalog

`Browser_capabilities` describes the public tools implemented for the exact
browser in an observation receipt. It performs no I/O, chooses no browser and
grants no dispatch permission. A connected browser retains its clientId; an
owned browser retains its selected backend and tab IDs. A capability gap never
authorizes moving a tab, copying a login or replaying input elsewhere.

Each typed operation is available, conditional, or unsupported. Available means
the adapter implements the public operation, not that a browser session is open
or a page accepted an effect. Conditional rows name the tool, action or read mode
and material constraints. Unsupported families remain visible, including window
management, viewport resizing,
touch, clipboard, network interception, console and storage access. Internal
JavaScript or debug-protocol availability does not expose those capabilities to
an agent through a public tool.

## Workflows

- Native BiDi, owned Gecko and owned Chrome support observed scene → hover →
  fresh scene → click → inspect application state. WebExtension does not serve
  trusted hover; its DOM click does not provide native pointerdown menus.
- Pointer dragging and HTML5 DataTransfer/drop acceptance are different. Chrome
  has a passing native HTML5 fixture; application acceptance still requires a
  fresh read. Firefox's tested HTML5 case fails despite pointer drag working.
- Fill replaces an input/textarea value and emits input/change; it does not mean
  trusted typing or submission. Owned Gecko alone exposes BrowserAct's limited
  native-select, frame, dialog, sandbox upload and download operations. Native
  adapters expose typed double click, focused Unicode text, and modifier chords;
  text controls are refused, and Chromium supplementary keys require type_text.
  Uncertain Chromium key release quarantines its exact session without closing
  pages: inspect status, then explicitly close/reopen to recover.
- WebExtension 0.8.0+ exposes genuine browser zoom (factor 0.3–5) with measured
  scale and scope. Per-origin zoom can affect same-origin tabs. Refresh the scene
  and screenshot afterward; native adapters explicitly refuse zoom.
- Owned Chrome serves native open_tab and top-level back/forward/reload/close_tab.
  A created tab remains in a partial receipt when its navigation fails; inspect
  it before another create. Frame/general BrowserAct actions stay unsupported.
- Owned Chrome exposes model-mediated sentence actions separately.
- Safari has no MASC adapter. Installing Safari or having its driver executable
  does not create a connected browser. Its current catalog is unsupported.

Observe the exact browser's tab inventory first. Use an explicit observed tab
for scenes and screenshots, with the owning Keeper for screenshot retention.
After success, partial effect, cancellation or unknown outcome, read that same
browser/tab before deciding whether another effect is needed. A receipt for
native input describes dispatch, not completion of the user's task.

## Initial task requirements

`BrowserTabs(requiredActions=["hover","type_text"])` discovers an already
connected/open browser implementing the task. `BrowserSession(action="open",
requiredActions=["read_frames","list_downloads"])` can choose an eligible owned
browser before opening it. Selection itself performs no command, navigation or
replay. Explicit owners never change to satisfy requirements. Required actions
are a closed list of catalog operation names, not tool names or arbitrary code.

The discovery receipt includes `browserCapabilities` and `browserSelection`.
Retain that concrete identity on every later tab/document call; a feature gap
never authorizes moving an existing tab. `required_browser_actions_unavailable`
includes requested actions and candidate `missingActions` in both structured
data and model-facing raw output. For example, no current adapter combines
`page_zoom` and `type_text`, so that requirement fails before dispatch.
Conditional rows mean implemented subject to their listed constraints: they do
not prove current session readiness, focus, permission, version or effect success.
