# Composite browser region observation

Source tested: `8e43efa86c8487e227f9c84733e341dff6555fdb`.

The stock Firefox probe passed 62 checks. The new cases verify a visible overflowing pane without landmarks, resolving its scope to body content, and retaining both a landmark and a separate scrolling pane. Existing cases cover shared node references, clipping, interactions and navigation. `regions.json` records the synthetic semantic fixture and scoped-read size comparison; it is not a Slack capture.

Reproduce with existing Firefox and geckodriver binaries:

```sh
python3 test/test_browser_scene.py --driver /path/to/geckodriver --browser /path/to/firefox --out /tmp/browser-region-proof
```

This proves execution of the shared browser script in a synthetic Gecko page. It does not prove installed extension identity, actual Slack pane discovery, Keeper Composite invocation, or physical TUI agreement. These remain live acceptance work. No user page data is included.
