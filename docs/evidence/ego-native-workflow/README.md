# Ego native workflow

BrowserInteract `action=workflow` sends a known sequence of native Page calls,
its native wait and one final snapshot through the existing browser broker.
The typed command exposes ten Page methods; it does not evaluate agent-supplied
Node code. Ego owns locators, actionability and each SDK wait. MASC retains
connection identity, cancellation, initial observed URL and progress receipts.
A failed step stops the sequence without replay. Input failure can be uncertain.
The observed URL check precedes SDK entry and does not atomically guard input.

## Measured evidence

- Installed Ego 0.6.0.20: `fill`, `selectOption`, `click`, `waitForURL`,
  `waitForSelector` completed in one invocation, then returned a final snapshot
  from the navigated page. The page showed the submitted value and selection.
- A wrong initial URL refused before input. A native wait failure after hover
  preserved one completed step and did not run the later navigation.
- [proof.json](proof.json) binds request/result to production JavaScript SHA-256
  `ec68b350de8b99c2f49451b26ef99492b2764f021e74d866ca1b6a64512e7558`.
  [sdk-output.txt](sdk-output.txt) and [native-workflow.png](native-workflow.png)
  record the result. The screenshot was visually inspected.
- `scripts/check-browser-native-workflow-codec.sh`: five component tests passed;
  actual `.mli`/`.ml` codec and receipt sources compiled with warnings as errors.
  Its `--proof docs/evidence/ego-native-workflow/proof.json` mode decoded the real
  browser receipt against its exact request. This uses library-name aliases and
  does not type-check the host integration.
- `node --test test/test_browser_ego_workflow.cjs test/test_browser_ego_target.cjs
  test/test_browser_ego_drag.cjs`: fourteen production-script scenarios passed.

## Scope still to verify

This proves production JavaScript on installed Ego and the OCaml codec/receipt
component. It does not prove OCaml host dispatch, installed MASC replacement or
an autonomous Keeper task. Added host/client scenarios require selected suite
execution. No local Dune build or full regression run is claimed.

Continue the overall native-first work in issue #45726, including remaining
input adapters and a real Keeper task. The goal's continuing task space is 4;
reuse it and finish only when the whole goal ends.
