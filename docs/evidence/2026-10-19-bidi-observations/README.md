# BiDi observation work

The source hashes and check results are in [proof.json](proof.json).
[elements.txt](elements.txt) records four passing Node tests, including current
control state, sensitive input exclusion, Unicode text, visibility changes and
parity with the unchanged WebExtension inventory. In its eight-control fixture,
computed-style API reads decreased from 40 to 10; this is not a latency result.

Firefox 158.0 passed all 158 checks in the shared-script Gecko probe. The added
checks install a throwing `document.body.innerText` getter, then execute the
capture guards and shared pointer receipt. A screenshot still succeeds and a
subsequent scroll changes the guard. [The captured fixture](capture-without-text.png)
contains only test data. An initial probe failed because its small fixture could
not scroll; the fixture now explicitly provides scrollable height.

Reproduce with existing browser binaries, without a MASC build:

```sh
node --test test/test_browser_elements.cjs
python3 test/test_browser_scene.py --driver /path/to/geckodriver \
  --browser /path/to/firefox --out /tmp/bidi-scene-proof
ocamlc -stop-after parsing -c lib/browser_bidi_peer.ml
ocamlc -stop-after parsing -c test/test_browser_bidi_peer.ml
git diff --check
```

Verification scope: `Browser_page_script.elements` is consumed by native
WebDriver, Stagehand and BiDi observations; the Node and Gecko probes execute the
shared JavaScript itself. The BiDi peer's OCaml dispatch tests add implicit
selection past an unreadable tab and URL/document/scroll capture rejection.
Those Alcotest cases were added and syntax-parsed, but not built or executed.
The external coding workflow does not run local Dune builds or full CI.

An independent subagent reviewed function, logic and code cleanliness. It found
a deleted-helper reference in pointer receipt handling; the final code uses
the existing shared `pointer_receipt_script`, whose consumer contract does not
require whole-page text. The reviewer re-read that delta and found no remaining
P0/P1/P2 finding. This source review is not a formal GitHub approval.

These checks do not establish installed-host behavior, authenticated Slack
timeout recovery, or image-analysis provider latency. A partial tabs inventory
is not proof that an explicitly selected readable tab is blocked. The PR does
not change browser permissions or close tabs. Protocol reference:
[WebDriver BiDi screenshot and script commands](https://www.w3.org/TR/webdriver-bidi/).
