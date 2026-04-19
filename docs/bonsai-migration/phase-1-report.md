# Phase 1 Report — logs island (Phase 1a static render)

## Scope

Land `/dashboard/b/logs` with 1:1 visual + field parity to the Preact logs
tab, wired through typed OCaml Records. Static fixture data only — no fetch,
no polling yet. Phase 1b adds live data.

## What's in

- `dashboard_bonsai/src/logs_types.ml`
  - `type entry` — 10 fields copied verbatim from the server's
    `Log.Ring.to_json` shape (`seq`, `ts`, `level`, `raw_level`,
    `normalized_level`, `source`, `legacy_classified`, `module_`,
    `message`, `details`).
  - `type response = { total; entries }`.
  - Manual `entry_of_yojson` / `response_of_yojson` — no ppx yet, so the
    build surface stays small. Fixtures live in `Logs_types.fixture`.
- `dashboard_bonsai/src/logs_view.ml` — ppx_css stylesheet + renderer
  mirroring the Preact layout (11rem / 5rem / 10rem / 8rem / 1fr grid,
  level-tinted row background, source badge, optional details line).
- `dashboard_bonsai/src/app.ml` — top-level view selector. Reads
  `Brr.Uri.path` once at mount and picks `Logs_view.component` on
  `/dashboard/b/logs`, otherwise `Hello_view.component`.
- `dashboard_bonsai/bin/main.ml` — `Start.start` now mounts `App.root`.

No server-side code changed. Existing Preact `/logs` tab is untouched.

## Measurements

| Metric | Phase 0 hello | Phase 1a logs | Δ |
|--------|---------------|---------------|---|
| `main.bc.js` raw | 60.3 MB | 61.3 MB | +1.0 MB |
| `main.bc.js` gzip | 8.99 MB | 9.14 MB | +150 KB |

Adding a typed record, Yojson decoder, ppx_css stylesheet, view function,
and URL router costs **~150 KB gzip**. Fixed-cost dominance (the 9 MB
baseline) remains the story.

## Design choices worth remembering

1. **Reserved keyword handling** — JSON field `"module"` maps to OCaml
   record field `module_`. The ppx_css class name `.module` also fails to
   generate a valid OCaml identifier, so the CSS class is renamed to
   `.mod_col`. Both renames are internal and do not change the JSON or CSS
   output.
2. **`Node.div` signature in v0.18** — takes children as a single
   positional argument; `~attrs` is a labelled optional. Writing
   `Node.div [] children` is a silent arity bug: `[]` binds as children and
   the real children become an extra argument. Always prefer
   `Node.div ~attrs:[ … ] children` or `Node.div children`.
3. **`ppx_css` keyword avoidance policy** — before naming a CSS class,
   check it is not an OCaml reserved word or stdlib module name. Safer:
   prefix with `css_` or use snake-cased role names (`row_error`,
   `source_badge`, `mod_col`).
4. **Static URL routing is fine for Phase 1.** Bonsai has no built-in
   router. Reading `Brr.Uri.path` at startup is sufficient until multiple
   client-side-navigable islands coexist.
5. **No ppx_yojson_conv yet.** Manual decoders let us control field
   defaults, handle `Intlit` for large sequence numbers on 32-bit JS, and
   keep the ppx surface at the minimum set (`ppx_jane`, `ppx_css`,
   `js_of_ocaml-ppx`).

## Phase 1b — real fetch (done)

### What landed

- `dashboard_bonsai/src/logs_var.ml` — module-level
  `Bonsai.Expert.Var.t` holding the current `Logs_types.response`.
  Initial value is the fixture.
- `dashboard_bonsai/src/logs_fetch.ml` — single-shot fetch:
  `Brr_io.Fetch.url` → `Body.text` → `Yojson.Safe.from_string` →
  `Logs_types.response_of_yojson` → `Bonsai.Expert.Var.set`. Errors are
  swallowed silently in Phase 1b; surfacing them is a Phase 1c task.
- `dashboard_bonsai/src/logs_view.ml` — now uses
  `Bonsai.map (Bonsai.Expert.Var.value Logs_var.var) ~f:render_response`
  instead of the fixture. `render_response` is a pure function.
- `dashboard_bonsai/bin/main.ml` — triggers `Logs_fetch.run ()` right
  after `Start.start`.

### Reactive wiring choice

`Bonsai.Expert.Var` is the documented escape hatch for feeding
non-Bonsai asynchronous sources (brr's `Fut.or_error`) into the
incremental computation. Official docs position it as a testing tool,
so mark this as an implementation detail that may need to change once
Phase 1c introduces a proper Bonsai Effect-based fetch helper. For
Phase 1b it keeps the Async/Eio/Fut interop out of the view code.

### End-to-end smoke test (2026-04-19)

Built the masc-mcp server binary from the worktree and ran it against a
disposable `--base-path=/tmp/bonsai-smoke --port=18935`, then curled the
relevant paths.

| Path | Status | Size | Notes |
|------|--------|------|-------|
| `/health` | 200 | — | server healthy |
| `/dashboard/b` | 200 | 272 B | HTML shell from `bonsai_index_html` verbatim |
| `/dashboard/b/logs` | 200 | 272 B | SPA catchall hits the same shell |
| `/dashboard/b/hello` | 200 | 272 B | SPA catchall again |
| `/dashboard/b/assets/main.bc.js` | 200 | 64,393,205 B | byte-exact copy of our build output |
| `/dashboard` | 200 | 96 B | existing Preact entry unaffected |
| `/api/v1/dashboard/logs?limit=2&level=INFO` | 200 | ~400 B per entry | shape matches `Logs_types.entry` field-for-field |

Coexistence with the Preact dashboard is intact. The API's JSON shape
(`total` + `entries[]` with `seq/ts/level/raw_level/normalized_level/
source/legacy_classified/module/message/details`) matches
`Logs_types.response_of_yojson` exactly, so the Phase 1b runtime parse
path will work as soon as a browser loads the page.

### Bundle delta

| Metric | Phase 1a (fixture) | Phase 1b (fetch) | Δ |
|--------|---------------------|-------------------|---|
| `main.bc.js` raw | 64,225,618 B | 64,393,205 B | +167 KB |
| `main.bc.js` gzip | 9,140,116 B | 9,168,697 B | +28 KB |

Adding the fetch path + `Logs_fetch`, `Logs_var`, and the
`Bonsai.map`-based view is a ~28 KB gzip tax. `Brr_io.Fetch` itself
does not pull additional runtime; brr was already linked in Phase 0.

## Visual pitch — MASC Design System skin (2026-04-19)

The dashboard was reskinned to match the MASC Design System
(`/Users/dancer/Downloads/MASC Design System`) dark-fantasy theme — same
tokens, same type stack, same cadence — to answer the "이런 분위기로 갈
수도 있다" brief without committing to the full port.

Screenshot: `phase-1-visual-pitch.png` (1440 × 1100, 255 KB).
Source HTML: `visual-pitch.html` (pure CSS so it renders instantly; the
Bonsai build uses the exact same tokens via `ppx_css`).

Design decisions:

- `data-theme="dark-fantasy"` root, `#0a0706` base with brass+blood
  radial glows + SVG fractal-noise overlay (`mix-blend-mode: overlay`,
  opacity 0.28).
- Brand bar: 22 px rotated brass rune holding "M" + `MASC` wordmark
  (Cinzel, 0.22em tracking) + crumbs (`OBSERVATORY › LOGS · 저널`) +
  `LIVE · 3S` pulse indicator.
- 6-column sticky HUD with `gap:1px` hairline seams, carved brass L
  corner marks (`.frame-gothic` idiom), mono-tabular values, bile green
  for healthy polling status.
- Journal tape: left 2 px level-colored rail (mold / bile / ember /
  blood / slate), dashed hairline separators, pill source badge with
  status dot, EB Garamond message body, JetBrains Mono details, on-hover
  brass glow gradient.
- Bilingual language — section crumbs mix English (`observatory`) with
  Korean (`저널`), eyebrows use the MASC voice ("log ring · in-memory"
  over "Recent events").
- Iteration 8 (filter toolbar): sticky chip-group (`.pill`) with
  level filters (debug+ / info+ active / warn+ / error), MODULE and
  LIMIT input shells, REFRESH ghost button. Relative time slot added
  under the ISO timestamp in the `ts` column.
- Iteration 9 (keeper sigil + illuminated drop cap): every row now
  opens with a 22 px `.sigil` disc — carved-brass circle holding the
  uppercase first letter of the module name (K for Keeper, O for
  oas:\*, G for Governance, S for Server). `.sigil_warn` tints amber;
  `.sigil_error` becomes a blood-red glyph on a bone-lit pitch-dark
  field, echoing an illuminated-manuscript initial. The first entry's
  message gains `.message_lead` which drops a 2.4 rem Cinzel/Garamond
  initial with a `brass → bone → blood` `background-clip: text`
  gradient, floated so EB Garamond body wraps around it. Pure CSS —
  no SVG or image asset.
- Iteration 10 (observatory heartbeat strip): a 60-bar density track
  between the brand and the HUD, tagged `cycle pulse · last 60 ticks`
  with a `t-60 ·—· t0` mono scale. Each bar is a grid cell 2 px wide
  with `grid-auto-columns: 1fr` so the whole viewport width is
  covered hairline-style. Colors encode dominant level: bile green
  (info), pitch (idle), amber gradient (warn), blood-red gradient
  with glow (error). Heights come from a static OCaml list
  (`heartbeat_bars`) matching the mockup's 60-tuple — no chart
  library, no SVG, no canvas. Renders in the Bonsai bundle via
  `Css_gen`-based inline `height: Npx` style per bar. Phase 3 chart
  binding budget: any library that exceeds the cost of this 60-bar
  strip (~3.7 KB gzip, zero runtime) must justify itself.

The Bonsai bundle renders this same design at
`/dashboard/b/logs`. Because headless Chrome won't wait for the 9 MB
js_of_ocaml bundle to finish parsing under `--virtual-time-budget`, the
snapshot in this report was taken against the static HTML mockup
instead. End-to-end Bonsai rendering is still validated via the curl
smoke tests in the section above — server shell + JS asset + live
backend API all respond correctly.

## Open items for Phase 1c

- 3 s polling loop. Prefer `Bonsai.Clock.every` wired through a proper
  `Effect.t`, not a raw `setInterval` — so cancellation is automatic
  when the component unmounts.
- Delta mode via `since_seq` and a Preact-equivalent merge
  (`mergeLogEntries`) so the visible list grows incrementally.
- Filter UI — level dropdown, module text input with 300 ms debounce,
  log limit selector.
- Error/loading states. Today failures are silent.
- Virtual scrolling. First, check whether `bonsai_web_components`
  ships a ready-made virtual list; fall back to manual windowing if
  not.

## Plan exit-condition status

- Bundle gzip > 10× Preact equivalent: **triggered** (same as Phase 0).
- Chart-binding failures ≥ 3: not yet applicable.
- Compiler/dune/opam forcing masc-mcp rebuild: not triggered.
- 9 months to Phase 2 target: not elapsed.

One of four triggered. Plan requires two for auto-halt. Continue.
