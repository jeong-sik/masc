# Native Ego workflow

Choose the observed live Ego `clientId` and `tabId`, read the page, then send
`BrowserInteract` with `action: "workflow"`, its observed `expectedUrl`, and
the planned `steps`. The entire sequence ends with one native snapshot. A
failure or dialog stops following steps and returns the completed prefix.
Do not replay that prefix when input may already have happened.

Each step's optional `options` object uses the installed SDK's names and
milliseconds. Options are validated for that exact method. Omission preserves
the SDK default. For example:

```json
[
  {"method":"fill","selector":"loc=css:#editor","text":" append","options":{"clearFirst":false,"timeout":3000}},
  {"method":"selectOption","selector":"loc=css:#choice","selectionJson":"{\"label\":\"Beta\"}","options":{"timeout":3000}},
  {"method":"click","selector":"loc=css:#submit","options":{"button":"left","position":{"x":8,"y":8},"label":"Submit selected choice"}},
  {"method":"waitForLoadState","options":{"timeout":5000}}
]
```

Use selectors from current page observations. `selectionJson` contains one JSON
value: a value-or-label string, `{value?,label?,index?}`, a mixed array of those
choices, or `null`. An empty array also clears selection. The SDK decides how
the actual select element behaves, including programmatic disabled-option
selection; MASC preserves the requested selection forms.

| Methods | Native options |
| --- | --- |
| `click` | button, clickCount, delay, position, force, timeout, label |
| `dblclick` | button, delay, position, force, timeout, label |
| `hover` | position, force, timeout, label |
| `dragAndDrop` | button, sourcePosition, targetPosition, force, timeout, label |
| `mouse.click` | button, clickCount, delay, label |
| `mouse.move` | steps, label |
| `mouse.wheel` | label |
| `fill` | clearFirst, timeout |
| `press` | delay, timeout |
| `focus`, `selectOption`, `waitForURL`, `waitForSelector` | timeout |
| `goto` | referer, timeout, waitUntil |
| `reload` | timeout, waitUntil |
| `keyboard.type`, `keyboard.press` | delay |
| `waitForLoadState` | timeout, idleMs |
| `waitForFunction` | timeout, polling |
| `fetch` | timeout, method, headers, body, cache, credentials, integrity, keepalive, mode, redirect, referrer, referrerPolicy |

`evaluate`, `keyboard.insertText`, and `keyboard.paste` accept no options.
`keyboard.paste` accepts step `text` and optional `html`. Only pointer actions
accept an option `label`; MASC prefixes it with the actor's identity.
`waitForSelector` takes step `state`. `waitForLoadState` has an optional step
`state`, whose omission uses the SDK default.

`mouse.click` and `mouse.move` take observed CSS-pixel `x`/`y` coordinates.
`mouse.wheel` uses `x`/`y` as horizontal/vertical deltas: first move or click
over the observed scroll container within this same workflow invocation.
`dragAndDrop` takes `selector` and `destination`, both observed locators.
If a pointer click or drag fails, one release of its exact button is attempted.
A lost key press/type response keeps release unconfirmed without guessing a
key-up sequence. An unconfirmed release prevents further input on that
connection. The result reports `inputReleased` independently of completed
effects; neither a cleanup nor a guard makes the failed action successful. Manual held-button and held-key workflows
are not exposed.

`evaluate` and `waitForFunction` take browser `source` and optional
`argumentJson`. The source never executes in the host Node process. Page code,
including a wait predicate, can have effects before failing. `fetch` accepts
HTTP(S) absolute or page-relative URLs and returns its native response receipt.
`saveAs` requires a brokered download path and is not exposed here.

These options are integrated in source with standalone codec and forwarding
checks. The updated real-browser probe could not run because verification
Space 27 disappeared before its first page operation. Installed MASC, Keeper
dispatch and visible UI behavior for this extension remain unverified. See
[the SDK inventory](ego-sdk-coverage.md) for evidence and remaining capabilities.
