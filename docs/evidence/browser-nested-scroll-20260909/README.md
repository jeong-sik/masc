# Nested-pane browser scroll

Real Firefox/Gecko fixture with independent message and sidebar panes. Shared script scroll_at moved only the message pane by 120 CSS pixels. Native WebDriver wheel dispatched trusted input and moved that same pane while sidebar and document remained at zero. The final screenshot shows the reverse-flow message pane after a negative scroll. The native-wheel check uses the production call order through screenshot capture without polling or sleeps; this establishes observed movement on this Firefox fixture, not complete settling on every page. A separate assertion verifies column-reverse chat uses negative scrollTop without scrolling the root.

Run test/test_browser_scene.py with an installed geckodriver and Firefox; arguments are documented in ../browser-pointer-20260909/README.md. proof.json records assertions and screenshot digest; driver.txt is the actual driver log.

Scope: shared fixed scripts and native protocol, not the compiled MASC dispatcher/TUI or actual Slack. The live extension follows scrollable DOM ancestors; native automation delegates wheel targeting to Firefox. No claim of Slack collection performance yet.
