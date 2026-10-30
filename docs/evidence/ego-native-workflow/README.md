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
  `ff96902e331b3b8ea0e3d07b1d4dcb8ebb2d638218104276bc29ed6b1e29d061`.
  [sdk-output.txt](sdk-output.txt) and [native-workflow.png](native-workflow.png)
  record the result. The screenshot was visually inspected.
- `scripts/check-browser-native-workflow-codec.sh`: five component tests passed;
  actual `.mli`/`.ml` codec and receipt sources compiled with warnings as errors.
  Its `--proof docs/evidence/ego-native-workflow/proof.json` mode decoded the real
  browser receipt against its exact request. This uses library-name aliases and
  does not type-check the host integration.
- `node --test test/test_browser_ego_workflow.cjs test/test_browser_ego_target.cjs
  test/test_browser_ego_upload.cjs test/test_browser_ego_drag.cjs`: nineteen
  production-script scenarios passed at the repaired runtime source.

## Viewport scope repair

An actual Keeper on candidate `4219c3074e281940ffec9c0d0b12db6f04a0d296`
reproduced a workflow-only failure: MASC's `viewport` was sent as an SDK scope,
which Ego rejects. The same Keeper then used `full_page` successfully. Complete
request/results are in [viewport/keeper-original-host.json](viewport/keeper-original-host.json).

Viewport now calls `page.snapshot()` with the SDK default, as BrowserRead does;
full-page still sends the native `full_page` scope. The fixture now enforces
the installed SDK scope contract: two failures before, seven tests passing
after. [viewport/sdk-proof.json](viewport/sdk-proof.json) records the fixed
production script completing two native waits and the viewport snapshot on
installed Ego in the same approved space 9. The five-step full-page SDK proof
above was also re-executed with the fixed script. These direct SDK results do
not prove a replacement host binary; candidate verification is separate.

## Evidence scope

The SDK proof and OCaml component check have their stated scopes. The original
candidate's real Keeper receipts additionally prove its full-page workflow
host dispatch and expose its broken viewport branch. They do not prove the
repaired host binary or installed MASC replacement. No local Dune build or full
regression run is claimed.

Later host/Keeper verification is in the [integration audit](../ego-native-integration/).
It includes the repaired candidate's actual viewport workflow receipt, one
persisted submission and independent rendered-page inspection. Initial spaces
4 and 9 were found missing; the operator authorized replacement spaces for this
goal. Final space 14 ended through explicit Add-on retirement after verification.

## Tool loader repair

Selected CI run 40073172999 compiled all seven selected suites. The workflow
codec (5 tests) and browser-lane routing (14 tests) passed; other suites failed
at tool initialization because the production TOML loader requires table
arrays for nested params. General TOML syntax validation had not proved that
contract. The workflow declaration now uses [[params.items.params]].
[schema-load-before.txt](schema-load-before.txt) reproduces the failure with
the real loader; [schema-load-after.txt](schema-load-after.txt) loads both
Interact/Act declarations. [schema-load.json](schema-load.json) binds the
loader/interfaces and declarations to SHA-256. This is component loading,
not full server startup or a passing re-execution of those suites.
The later selected-suite execution and running candidate are recorded separately
in the integration audit.

