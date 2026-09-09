# Screenshot pointer backend probe

Real Firefox 155, geckodriver 0.37.1, isolated public fixture. Run:

```sh
python3 test/test_browser_scene.py --driver <geckodriver> --browser <firefox> --out <evidence-directory>
```

The probe executes the repository's shared scene, DOM interaction and pointer guard scripts. It verifies screenshot-coordinate click, native trusted pointer press/move/release, and stale viewport rejection after scroll/reload. `proof.json` records scope, script digest, screenshot digest and timings; `driver.log` and `fixture.png` preserve runtime evidence.

The native Actions sequence is exercised directly through WebDriver. This does **not** execute the OCaml dispatcher, installed MASC binary, TUI, or Slack. CI must cover the OCaml boundary; TUI and Slack acceptance remain outstanding.

Viewport identity covers document reload, dimensions and top-level scroll. It is not a frozen-page transaction: same-document layout changes and changes between validation and input remain possible. Refresh after an interaction and inspect the resulting page.

Implementation reuses [WebDriver Actions](https://www.w3.org/TR/webdriver2/#actions). Live extension click uses DOM activation; trusted drag uses the automation backend.
