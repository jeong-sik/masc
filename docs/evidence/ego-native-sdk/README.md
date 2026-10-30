# Ego native SDK input

Ego selector and snapshot input use the installed SDK's locator and Page
methods. MASC retains connection identity, ownership/cancellation, effect
receipts and sandbox file transfer. It supplies adapters for scene references
and operations for which the SDK has no matching primitive.

The implementation calls `page.click`, `fill`, `hover`, `dblclick` and
`selectOption`. It does not first resolve selector targets to coordinates,
change their DOM values, or add its own selector/actionability timeout.
`selectOption` receives exact `{value}` objects, including arrays and an empty
array; it follows Ego's programmatic selection semantics (disabled options are
selectable). Native method failures are uncertain and are never replayed.
The URL check precedes SDK entry and does not atomically guard a later input.

## Evidence

- Installed `ego-browser 0.6.0.20`, Chromium 154.0.8037.44, bundled Node v24.21.0.
- `node --test test/test_browser_ego_target.cjs test/test_browser_ego_drag.cjs`:
  eight scenarios passed. These substitute the SDK and execute the production
  JavaScript functions, covering pre-effect URL refusal and uncertain native
  failures without replay.
- `node scripts/probe-browser-ego-native-sdk.mjs EGO OUT SPACE`: fifteen
  observations on the real browser through the production native-input
  function. The probe verifies exact single/multiple/empty option selection,
  disabled-option SDK behavior, trusted offscreen and shadow clicks, native
  hover/double click, cross-origin frame locator/ref input, dialog dismissal
  followed by input, and wrong-URL refusal. It uses SDK waits and a final
  snapshot in the same Node invocation. This demonstrates SDK behavior,
  **not a Keeper workflow API**.
- [proof.json](proof.json) binds those observations to the production function's
  SHA-256; [sdk-output.txt](sdk-output.txt) includes the final snapshot;
  [native-sdk-results.png](native-sdk-results.png) was visually inspected.
- `ocamlc -stop-after parsing` passed for the changed OCaml files; TOML decode
  and `git diff --check` passed.

No local Dune build, OCaml type check, OCaml suite execution, Add-on dispatch,
installed MASC replacement, or autonomous Keeper scenario is claimed here.

## Integration follow-up

This folder's SDK proof was the first layer, not completion of the overall
objective. The [workflow layer](../ego-native-workflow/) adds the known sequence,
SDK wait and final snapshot through the existing broker. The
[transfer layer](../ego-native-transfers/) audits the remaining adapters and
keeps demonstrated SDK gaps plus sandbox/file ownership responsibilities.

The [integration audit](../ego-native-integration/) records later exact-source
CI, real-provider Keeper tasks and runtime identities, including the viewport
defect those tasks exposed. Host Node filesystem/process access remains outside
the browser capability: no Keeper-supplied AsyncFunction or new locator engine.
Existing handoff/ownership refusal is covered by peer contract tests; a new
human-interaction scenario is not claimed. Actual uncertain input and subsequent
observation are retained in the real Keeper records.

The historical SDK proof records space 4. It was later found missing and the
operator explicitly approved continuing in 9; the integration audit tracks its
lifecycle. Do not create replacement spaces to recover from browser errors.
