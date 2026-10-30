# Browser source context: first implementation evidence

The real Vite development transform annotates HTM templates and native JSX
nodes with checkout-relative source coordinates and SHA-256. The shared Gecko
scene reader carries this context to BrowserRead. JSX coordinates describe the
opening element; HTM coordinates describe the enclosing tagged template.

| Browser | Mounted source targets | Checks | Source edit and browser readback |
| --- | ---: | ---: | --- |
| Zen | 24 | 83 | Count → Clicks, fresh source hash, click increments |
| Firefox | 24 | 83 | Count → Clicks, fresh source hash, click increments |

[Zen receipt](zen.json) · [before](zen-before.png) · [after](zen-after.png)

[Firefox receipt](firefox.json) · [before](firefox-before.png) · [after](firefox-after.png)

Each target's original file hash and declared position are checked against disk.
The selected control supplies the file used for one exact fixture source edit.
The probe observes the changed hash before accepting the new page, verifies that
an old document reference fails, exercises the changed button, and restores the
original file in `finally`. Browser profiles/processes belong to the probe.

The first post-review run found a test synchronization issue: a mounted button
could still belong to the pre-edit Vite module. The probe now waits for the
observed source hash rather than accepting DOM presence as freshness proof.

Reproduction, with existing Gecko binaries and a Vite dev server for this checkout:

```sh
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935 pnpm --dir dashboard exec vite --host 127.0.0.1 --port 5197 --strictPort
python3 scripts/probe-browser-source.py --driver /path/to/geckodriver --browser /path/to/browser --url http://127.0.0.1:5197/dashboard/browser-source-fixture.html --out /tmp/source-proof
pnpm --dir dashboard exec vitest run src/browser-source-context.test.ts
node test/test_browser_scene_resource.cjs
node test/test_browser_interact_extension.mjs
```

The source transform applies only during Vite serve. Ordinary external pages are
unmapped. Source metadata is a page-provided hint, not file-system authority;
resolve it in the chosen checkout and verify the source digest before editing.

Scope: actual Vite instrumentation, actual Firefox/Zen execution of the shared
scene script, and a scripted source edit/reload/interaction. New OCaml/TUI binary
execution and the proposed 10-task autonomous Keeper benchmark remain unmeasured.
No local Dune or production dashboard build was run.

References: [HTM](https://github.com/developit/htm),
[Vite plugin API](https://vite.dev/guide/api-plugin),
[React Grab prior art](https://github.com/aidenybai/react-grab).
