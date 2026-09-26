# Runtime lane editor browser evidence

## Source and scope

The portable harness ran against source commit `af7a80c4b87b9729a468e62f70f0c033cf1d6d64`.
Actual Chromium rendered the production `SettingsSurface`, API client and production
CSS import sequence. HTTP requests were intercepted with synthetic local responses;
no real server, runtime configuration write or deployment was involved.
The later commit adding this directory changes evidence only. Product source remains
byte-identical to the measured source tree recorded in `source-identity.json`.

## Measured behavior

All six assertions passed, with no browser page errors:

1. The lane displays the initial `rt-a`, `rt-b`, `rt-c` order.
2. After the synthetic file changes to `rt-c`, `rt-a`, `rt-b`, clicking `rt-b ↑`
   refuses the stale action without sending a POST.
3. The card displays that fresh file order and an explanatory error.
4. Retrying sends exactly `rt-c`, `rt-b`, `rt-a` with the freshly read source revision.
5. A synthetic HTTP 409 is displayed as a conflict.
6. The rejected write does not replace the card with an uncommitted order.

`receipt.json` records the actual request bodies and pass list. `source-identity.json`
records the source tree, selected source hashes, harness hashes and artifact hashes.
The three captured screens are:

- [Initial lane editor](01-lane-editor.png)
- [Stale click refused and fresh order shown](02-stale-click-refused.png)
- [Server conflict displayed](03-server-conflict.png)

The final portable rerun repeated the same six assertions. Screens were visually
inspected, including the final 409 screen. Earlier local harness setup errors
(wrong section, incomplete synthetic protocol inventory, incomplete style imports,
and Vite treating port zero as its default occupied port) were corrected before
this retained successful run; they were fixture setup, not product changes.

## Reproduce

Use this source checkout, or a later evidence-only head with the same dashboard source
and lockfile. Install its locked Dashboard dependencies and the matching Playwright
Chromium browser. Then, from the repository root:

```sh
node docs/evidence/runtime-lane-editor-2026-09-27/harness/run.mjs . /new/output/directory
```

The output directory must not exist. The harness checks source identity, selects a
free loopback port, serves a temporary component entry, intercepts all API requests,
and removes its temporary entry and closes the browser/server in `finally`.
It never connects to the live MASC API. `fixtures.json` contains synthetic API data
adapted from this revision's existing Settings tests. All fixture credentials are
synthetic. The harness requires existing dependencies; it performs no OCaml build.

## Limits

This is source-component browser evidence, not a packaged Dashboard or live backend
CAS execution. The server revision lock and admission behavior need their separate
repository/CI evidence. These screenshots do not establish deployment or Keeper
runtime continuity. Fresh PR checks are still required for the evidence commit.
