# Browser link semantics evidence

A stock Firefox instance with an isolated profile executed the fixed scene and interaction scripts from `9c29931398`. All 59 checks passed, including SVG href and visible-label handling, referrer-policy rejection before navigation, top-document `_top`/`_parent` targets, nested pane scrolling, and HTTP302 observation recovery.

The redirect scenario follows once, records the first observation, and waits for the canonical URL, new document identity and fixture content before capturing pixels. Background or navigation timing is not treated as application readiness.

Reproduce from the repository with `python3 test/test_browser_scene.py --driver /path/to/geckodriver --browser /path/to/stock/firefox --out /tmp/browser-scene-proof`. This is synthetic page-script evidence, not a deployed Keeper/TUI or live Slack acceptance claim. No user workspace content is included.
