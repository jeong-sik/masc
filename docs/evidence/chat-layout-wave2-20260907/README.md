# Chat layout performance, wave 2

The 0.1 ms TUI/WebDashboard/OCaml/MCP objective remains unmet. This change
addresses long chat layout; it is not proof of deployed end-to-end latency.
Server PR #33972 separately merged as `07c0010154f62b0f0c619f556ab65491da3d1fa7`
after exact-head compilation/lint/typecheck and 118 OCaml behavioral tests.
Its deployed-binary speedup has not been measured.

## Change and correctness

A live trace showed hundreds of chat rows forcing a large synchronous layout
when the transcript read `scrollHeight`. Removing only the second animation
frame snap did not reliably help. Row containment alone reduced layout but
broke bottom pinning by 3301 px in the fixed workload; it was not retained alone.

The scroller now has one growing, chronological content wrapper. Its outer
flex direction makes zero the native bottom coordinate; history has negative
scroll coordinates. The DOM, visual message order, and tab order remain
chronological. Bottom following no longer reads `scrollHeight` or schedules
an additional frame callback. Growing the wrapper preserves top alignment
for empty and short conversations.

Offscreen rows use `content-visibility:auto` with a remembered measured height
and an initial 16rem estimate. Messages stay in the DOM. Day/unread dividers
retain their actual small size. Since containment changes fixed-position
containing blocks, inline image/SVG/artifact previews now portal to document.body.

## Measured source fixture

`results.json` records Chromium 149.0.7827.55, 1440×1000, exact file hashes,
401 fixed rows / 4819 DOM descendants, and three alternating samples per arm.
Both arms run the current source component with native bottom scrolling; the
control disables **only** row content visibility. This is a development-server
component experiment, not a production bundle or old-binary comparison.

| Metric | Full row layout median | Deferred row layout median |
| --- | ---: | ---: |
| Mount call | 96.2 ms | 54.2 ms |
| Layout through two frame callbacks | 40.048 ms | 2.502 ms |

The first control mount was colder and took 156.8 ms; all individual samples
remain in the artifact. Three samples per arm do not characterize p95/p99.
DOM creation, scripts, paint, network, and provider work still exceed the goal.

Browser assertions passed: initial bottom, jump-to-latest, pinned streaming,
history append preserving `layout-395` at exactly y=318.546875, top-aligned
empty/short transcripts, and a body-level preview covering the full viewport.
`preview.png` and `transcript.png` show synthetic source-rendered content.

`browser-engine-geometry.json` separately exercises native reverse scrolling
and content growth in installed Chromium 149, Firefox 151, and WebKit 26.5,
with and without content visibility. All six standalone geometry cases passed;
visible history anchors moved 0 px. This is not full-app or mobile Safari proof.
Touch rubber-band behavior and mid-history width changes remain unmeasured.

Local source typecheck and 191 existing/extended chat, accessibility, media,
and mobile-style tests passed. No production/Dune build was run. PR CI and
deployment evidence are separate follow-up requirements.

## Reproduce

With the dashboard dependencies installed, start Vite from `dashboard/` using
the normal development proxy configuration, then run from the repository root:

```sh
node scripts/harness/perf/chat_layout_probe.cjs http://127.0.0.1:5178 /tmp/chat-layout-evidence
```

The harness mounts the real ChatTranscript from
`dashboard/src/demo/chat-layout-perf-fixture.ts` in a browser-only page. It does
not send chat messages, call providers, or mutate server state. It saves raw
measurements and screenshots and fails its behavioral assertions on regressions.

The design follows [CSS content visibility and containment](https://www.w3.org/TR/css-contain-2/#using-cv-auto)
and the [CSS scroll-origin definition](https://drafts.csswg.org/css-overflow-3/#scroll-origin).
