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

## Remaining scope of the user goal

The overall native-first objective remains open:

1. Allow an agent's known action sequence, native wait and final snapshot to
   execute through one broker command. Keep host Node filesystem/process access
   outside the browser capability; do not expose the worker's host AsyncFunction
   to Keeper-provided JavaScript or build another locator/composition engine.
2. Audit the remaining Ego input helpers (scene targets, direct link navigation,
   scrolling, native drag, upload/dialog/download) against SDK methods. Keep
   only demonstrated gaps and MASC ownership/artifact responsibilities.
3. Verify the resulting host path and a real Keeper task, including human
   handoff and uncertain input. Source/fixture results alone do not close this.

The dedicated probe task space is retained for the continuing user goal. Its
ID is recorded in proof.json. Resume it rather than creating another space.
