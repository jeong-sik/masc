# Browser elements filter validation — 2026-10-23

Candidate implementation: `c2c3314a81b` (base `73028e4450921a3f130b7297d013c907df2e7f49`).

The stack was subsequently rebased on
`858499f2aeb5cbe2d8f271d4c9653ed93e501e56`; implementation is
`724f988e9fc29a4a3bed0208555dc8c188466f00`. The two measured page-script files
remain byte-identical to the candidate above. The new main's live BiDi framed
`elements` path also forwards both filters, with a source test added for its
wire arguments. After restacking, the Node checks still pass (9 items), all 18
changed ML files parse, and the public tool TOML parses. The new OCaml framed
read test was not executed; the DOM evidence is not a test of that transport.

The reported live `within` request failed because its answer lacked the required
`withinMatches` receipt. Current repository and installed-on-disk extension
scripts already contained `within`; their SHA-256 matched. This does not prove
which background script Zen was running. No Slack message or reaction was sent
while diagnosing this request.

## Executed checks

- `node --test test/test_browser_elements.cjs`: 8 cases passed, including both
  shipped readers, explicit custom rows, scope intersection, hidden nodes,
  password value withholding and invalid selector rejection.
- `node --test test/test_browser_interact_extension.mjs`: passed existing
  shared DOM interaction and extension dispatcher checks.
- `node --check connectors/browser/extension/background.js`: passed.
- `ocamlc -stop-after parsing`: 17 changed implementation/test ML files and the updated documented ego probe
  parsed. This is syntax only;
  no native compilation, type check, OCaml test execution or CI run was done.

## Real DOM fixture

The ego-browser CLI ran six observation cases in an isolated Chromium task
space. It evaluated the candidate native script and the actual `pageElements`
function extracted from candidate `background.js`; its `tabs.executeScript`
transport was a fixture adapter to the real page DOM. Both observations matched.
This proves page-script DOM behavior, not WebExtension transport or public
Add-on execution. The task space was closed after the test.

| Request | Visible results | Scope matches | Selector matches |
| --- | ---: | ---: | ---: |
| Unfiltered control inventory | 1 password control, no value | — | — |
| `within=#inbox`, `selector=[role=row]` | 2 custom rows | 1 | 4 |
| `within=:scope`, `selector=[role=row]` | 3 rows | 1 | 4 |
| Missing scope, row selector | 0 | 0 | 4 |
| Missing selector | 0 | — | 0 |
| Password selector | 1 control, no value | — | 1 |

Invalid CSS was refused by both scripts. The shared production
`interactInPage` script clicked the second returned row selector; the fixture's
delegated click handler changed the visible output to `Opened: second`.
This is a synthetic conversation list, not Slack or proof of trusted input.
See [measured results](result.json) and [screenshot](fixture.png).

## Remaining runtime verification

Install a build containing the change, run extension setup, reload the add-on in
Zen and rediscover its current clientId. A real scoped Slack read must confirm
both filter receipts before claiming the original DM workflow works. No live
server, installed binary, extension reload or logged-in Slack state was changed
by this PR.

Design reference: explicit scoped element selection is also described in
[Playwright's locator documentation](https://playwright.dev/docs/locators).
MASC uses the browser's ordinary CSS engine, not Playwright's extended selectors.
