# Design parity — measuring the dashboard against the keeper-v2 prototype

The prototype in `dashboard/prototypes/keeper-v2/` is the design's own artefact:
a mock-data React SPA that renders every surface from hardcoded rosters and
threads. The dashboard renders the same surfaces from a live backend. Comparing
screenshots of the two directly measures mostly the difference in **data** — the
live fleet has 33 keepers where the mock has 12, with different names, counts and
row heights — so the number moves when the backend does and says little about the
skin.

The harness removes the data variable. It renders **the prototype's own DOM and
mock data twice**: once with the prototype's stylesheets, once with the
dashboard's compiled stylesheet set. Same markup, same strings, same viewport;
the only difference is CSS. What is left is skin drift.

**What this cannot see.** Fixing the DOM is what makes the number mean something,
and it is also the number's boundary: a surface the dashboard rebuilt under
different markup can never lower this score, because the parity page never
renders the dashboard's markup. Every number in this file measures the skin.
Whether the dashboard renders the design's components at all is a separate
question with separate probes — `DESIGN-COMPONENT-PARITY.md`. It stands at 57.4% (2026-08-23),
against 0.9487 here, and `lanes.css` shows how far the two can drift apart: the
Lane Queue sub-view scores 0.959 and not one `dl-` class exists in `src`.

## Running it

```bash
cd dashboard
pnpm install

# 1. Compile the dashboard's stylesheets into one static file.
#    The sheet list is parsed out of src/main.ts, so the harness cannot drift
#    from what the app loads. Re-run after any CSS change (~3s).
node e2e/design-parity-css.mjs

# 2. Build the parity page (prototype DOM + that compiled CSS).
node e2e/design-parity-build.mjs

# 3. Serve dashboard/ statically and shoot both pages.
python3 -m http.server 8978 --bind 127.0.0.1 &
BASE=http://127.0.0.1:8978/prototypes/keeper-v2
SURF=overview,keepers,work,monitor,schedule,board,fusion,registry,approvals,logs,connectors,ide,command,lab
node e2e/design-parity-shot.mjs proto "$BASE/Keeper%20Agent%20v5.html?surface={s}" /tmp/parity "$SURF"
node e2e/design-parity-shot.mjs live  "$BASE/_parity-vendored.html?surface={s}"   /tmp/parity "$SURF"

# 4. Score.
node e2e/design-parity-score.mjs /tmp/parity "overview:overview,keepers:keepers,work:work,…"
```

Diagnostics, in the order they are usually needed:

| Tool | Answers |
|---|---|
| `design-parity-style.mjs <protoUrl> <liveUrl> <surfaces>` | which computed property differs, per class, and the conformance % |
| `design-parity-box.mjs <surface> <sel…>` | where an element actually landed (x/y/size) — what a cumulative offset needs |
| `design-parity-rules.mjs <url> <sel> <prop>` | which stylesheet rule wins that property (CDP `getMatchedStylesForNode`) |
| `design-parity-cssdiff.mjs <name…>` | vendored vs prototype stylesheet, with the repo's font-size tokenization normalized away |
| `design-parity-viewport.mjs <surface> [limit]` | elements that differ AND fall inside the captured 1600×1000 — a block at y=1934 can be repaired without the number moving at all |
| `design-parity-gaps.mjs [name…]` | selectors the design defines that the vendored kit does not |
| `design-parity-leaks.mjs` | selectors owned by both a legacy sheet and the kit, and the geometry the kit does not restate |

`design-parity-ssim.mjs` computes SSIM itself (11×11 gaussian, σ=1.5, Wang et al.
2004) over grayscale planes from ImageMagick. ImageMagick's own
`compare -metric SSIM` reports the identical number for SSIM and DSSIM in 7.1.2,
so it is not used for the metric.

The harness writes `prototypes/keeper-v2/_parity/` and `_parity-vendored.html`;
both are gitignored and regenerated.

## Reproducibility

The prototype is a live mock, not a static page, and three things in it moved a
measurement between runs of the identical page:

- `.thread` is bottom-anchored and its scroll-to-bottom races the layout. It
  settles either at the bottom (`scrollTop` 1907 of 1907) or at an earlier
  anchor (185), and nothing afterwards moves it. Those two states differ by the
  height of the visible column, which is a 4pp swing on keepers — and a 15pp
  swing when the two sides land on opposite states. The capture pins the thread
  where the app means it to sit.
- `alarm.jsx` fires an ambient notification five seconds after load and every
  sixteen after that. It is switched off through the prototype's own
  `window.MASC_NOTIFY` channel before any page script runs.
- `shell.jsx` re-rolls a random tok/s figure every 1.1s, so the page never
  reaches a state it can be compared in. Repeating timers of a second or more
  are cut; the one-shot ones stay, because the FSM phase advance
  (`act.ms || 1500`) is part of the state the design settles into.

On top of that a frame is only accepted once two consecutive captures are
byte-identical. With all four in place, four runs of the same page produce the
same bytes and two independent full-fleet runs produce the same mean to four
decimals. Without them, treat any difference under ~4pp as noise.

## Where it stands (2026-08-22, `Keeper Agent v5.html`, 1600×1000)

Two independent full-fleet runs, identical to four decimals.

| Surface | SSIM | | Surface | SSIM |
|---|---|---|---|---|
| board | 0.996 | | work | 0.975 |
| logs | 0.996 | | approvals | 0.966 |
| monitor | 0.995 | | registry | 0.955 |
| ide | 0.994 | | schedule | 0.945 |
| lab | 0.987 | | keepers | 0.913 |
| connectors | 0.986 | | overview | 0.842 |
| command | 0.979 | | | |
| fusion | 0.978 | | **mean** | **0.965** |

Twelve of the fourteen sit at 0.95 or above.

The two that do not are named causes, ledgered underneath, and neither is skin
drift. **overview** is the surface width decision — the design centres at 1280px,
the dashboard is full-width, and that was settled twice after seeing the
measurement. **schedule** is the one still worth digging into.

The board and work entries used to sit down here too, at 0.853 and 0.897, and
both were wrong for the same reason: the kit had been vendored selectively, so
rules for components the dashboard does not render were left out, and the design's
DOM rendered them unstyled. That was my rule, not the repo's — `audit-dead-surface.py`
covers OCaml exports and says nothing about CSS. The kit is a copy now, and the
two surfaces moved to 0.996 and 0.975 without a line of component work.

Style conformance — `getComputedStyle` compared property by property across every
classed element on all fourteen surfaces — is **97.51%** (52,444 of 53,781
declarations), from 85.85% before this pass. The largest remaining group is
`font-family`, which is the UA fallback the dashboard deliberately does not
reproduce (see below).

`settings` is not measurable: the prototype's `SURFACES` registry has no entry for
it, so `?surface=settings` is rejected and the page renders keepers.

## Measured at a second viewport

Everything above is 1600×1000. `keeper-v2/fleet.css` calls 1440px "the canonical
operator viewport", so the fleet was measured there too:

| | 1600×1000 | 1440×900 |
|---|---|---|
| mean | **0.948** | **0.942** |
| monitor | 0.995 | 0.928 |
| overview | 0.842 | 0.868 |
| schedule | 0.945 | 0.931 |
| keepers | 0.909 | 0.896 |

The narrower viewport scores lower, and monitor carries most of the drop. Below
1500px the kit's `--fl-cols` switches to a responsive tier that is tuned the way
the base value used to be — five tracks with a 160px action cell, and
`.fl-rhead span:nth-child(5)` hidden — all shaped by the live row's sixth cell,
which the mock's row does not have. It is the same defect the base track set had,
still sitting in the tiers.

It is not fixed here. The tier never fires at the measured viewport, so it moves
no number the bar reads, and splitting it touches the live surface's responsive
behaviour at three breakpoints — worth its own change with its own verification,
not a tail-end edit. The split follows the pattern already applied to the base
value: the design's tiers stay in `keeper-v2/fleet.css`
(`max-width: 1320px` → four tracks, `max-width: 720px` → three), and the live
tiers move to `v2-monitoring.css` under `.v2-monitoring-surface`, keeping the
1500px breakpoint and the column-shedding rule.

`design-parity-shot.mjs` takes `PARITY_W` / `PARITY_H` for this.

## Sub-views

The prototype deep-links `?surface=` and `?keeper=` and nothing else, so every
section tab and drawer — Lane Queue, the prompt book, all twelve Settings panes —
is reachable only by clicking. Measuring the deep-linkable surfaces alone leaves
most of the design unverified: Monitor has seven sections and Settings twelve,
and `?surface=settings` is rejected outright because Settings is not in the
prototype's `SURFACES` registry.

`design-parity-views.mjs` is the recipe list — a view is a surface plus the
clicks that open it — and the shot harness follows it. Twenty-one views,
2026-08-22 (parenthesised values re-measured 2026-08-23 after the re-sync):

| View | SSIM | | View | SSIM |
|---|---|---|---|---|
| ide-cursor | 0.996 (0.995) | | monitor-tools | 0.969 (0.969) |
| monitor-observatory | 0.995 (0.995) | | settings ×12 | 0.967–0.972 (same band) |
| monitor-journey | 0.993 (0.993) | | **monitor-lanes** | **0.959** (0.959) |
| | | | monitor-internal | 0.870 (0.870 — harness boundary, see below) |
| monitor-runtime | 0.984 (0.984) | | schedule-list | 0.868 (**0.953**) |
| | | | approvals-history | 0.796 (**0.891**) |
| | | | **mean** | **0.957** (**0.965**) |

The sub-views score *higher* than the top-level surfaces (0.957 against 0.949; after the 2026-08-23 re-sync both sit at 0.965).
Lane Queue at 0.959 and the prompt book at 0.971 say the `lanes.css` and
`prompt-book.css` vendoring landed — which had never been verified, only
assumed.

Three are short, and all three for the same reason: the dashboard built the
component differently, so there is no class for the vendored skin to attach to.
None is skin drift and none is fixable in CSS.

| View | What the design draws | What the dashboard renders |
|---|---|---|
| `approvals-history` 0.796 → **0.891** (re-measured 2026-08-23) | `.ap-hist-row` — a dense table, four-column grid, tone stripe down the left edge, inline stat line, pill filters | The dashboard now renders the design's `.ap-hist-*` vocabulary: decider pills backed by the live `decision_source` field, `.ap-hist-reason` fed by the audit record's `decision_reason`, Auto Judge in the summary stat line. Still carries fields the design has no slot for (judging model, ALWAYS rules). |
| `schedule-list` 0.868 → **0.953** (re-measured 2026-08-23) | `.sch-act` approve/deny/ghost buttons | No consumer at all. This is one of the v3-only mock operator-action selectors the earlier sync recorded and skipped; it is still true. The 2026-08-23 gain came from the schedule.css re-sync (`.sch-decision` tone classes + 720px rules restored). |
| `monitor-internal` 0.870 (re-measured 2026-08-23: 0.8704 — unchanged) | `.ia-badge`, `.ia-count`, `.ai-table`, `.ai-strip` — a named component vocabulary | Rebuilt onto that vocabulary 2026-08-23 — `internal-agents-monitor.ts` now emits `.ia-head`/`.ia-count`/`.ia-badge`/`.ai-strip`/`.ai-table` instead of inline Tailwind utilities. The SSIM number cannot move: this harness renders the design's DOM, never the dashboard's markup (see the top of this file). The rebuild is visible to `design-parity-components.mjs` instead — internal-agents reads 88.6% (31/35) there. |

The last one was the most instructive. A vendored stylesheet only lands where the
DOM speaks the same vocabulary; a surface assembled from utilities is opaque to
it no matter how faithful the CSS is. That is a component-level decision, not a
sync one — and it has since been made: the surface was rebuilt onto the design's
vocabulary on 2026-08-23, so the 0.870 above is the pre-rebuild score.

## Route coverage — what has and has not been looked at

The measured set is 46 views: 14 deep-linkable surfaces, 22 sub-views behind tabs
and drawers, and 10 more added after checking the prototype's own section lists
against the recipe file. Overall mean **0.965**; seven sit below 0.95.

| Below 0.95 | | Cause |
|---|---|---|
| overview | 0.842 | surface width, decided |
| work-kanban | 0.855 | `.wk-kcol-body` capped at 42rem with an inner scroll; the design lets the column grow and the page scroll |
| monitor-internal | 0.870 | harness boundary — rebuilt onto the design's `.ia-*`/`.ai-*` vocabulary 2026-08-23; SSIM cannot see dashboard markup, so it reads the pre-rebuild value by construction (component probe: 88.6%) |
| approvals-history | 0.891 | component rewritten; `.ap-hist-reason` is now fed by the live `decision_reason` field (2026-08-23), so the no-live-field gap is down to `.ap-hist-kind`/`-lat`; re-measured 2026-08-23: 0.891 confirmed |
| keepers | 0.913 | the prototype's missing CSS reset (buttons keep UA Arial) |
| lab-performance | 0.935 | Korean line-breaking, below |
| schedule | 0.945 | the prototype's missing CSS reset, as keepers |

### Live routes the design has no counterpart for

`WorkSection` is `work | board | sub-boards | planning | repositories |
verification`; the design's Work surface has three views (트리, 칸반, 검증) and
no sections. So **four live routes are unmeasurable by this harness** —
workspace/board, sub-boards, planning, repositories — along with monitoring/transport-health and monitoring/feature-health, both hidden
diagnostics. Nothing is drifting there; the design simply does not draw them.
`design-parity-components.mjs` is the only signal these surfaces have.

### Design views the dashboard has no route for

The prototype's monitor carries a 실행 슬롯 · 대기 section. There is no `lanes`
route in `config/navigation.ts` and no `dl-` class in `src` — `lanes.css` is
vendored for a surface that does not exist here. These are the component gap,
not the skin gap, and `DESIGN-COMPONENT-PARITY.md` carries them.

Lab's 감사 무결성 used to sit here too. It is gone from the prototype
(2026-08-23): the resilience subsystem whose hash-chain verify it drew was
removed in #28170, so the panel showed a subsystem that no longer exists —
hardcoded "활성" included — and would resurface as a component gap on every
re-sync. Removed with the Lab tab and the `lab-audit` parity view.

### Not vendored at all

`instrument.css` (388 lines) is a second tone layer, sibling to the vendored
`tempered.css`. The v5 export links only `tempered.css` and sets
`data-tone="tempered"` on `<html>`, so the tone ships in the design package
without being the one v5 specifies. Left alone deliberately.

## Unnecessary UI

`docs/DESIGN-EXTRA-UI.md` runs the reverse check — what the dashboard renders
that the design does not — and carries its own findings.

## Divergence ledger

Every surface below 0.94 is held there by something that is not skin drift. Each
entry names what it is, why it stands, and what it costs.

### Overview — the surface is full-width, the design centres it at 1280px

`keeper-v2/surfaces.css` carries an explicit note: *"OVERRIDE (intentional
divergence from prototype): full-width, left-aligned … per design direction the
dashboard fills the content area to match the other surfaces
(board/monitoring/command/lab/ide). Do not re-add max-width / margin:auto on a
prototype re-sync."* The design still centres it in v5, and the note predates
this design drop, so it was put to the operator twice.

The first time, restoring the centring would have left the fleet mean short of
the 95% bar anyway, and the recorded decision stood. After the monitor, IDE and
Work repairs it became the only remaining lever — this one line is the whole
difference between 0.949 and 0.960 — so it was put again with that number
attached. **Re-confirmed on 2026-08-22: the surface stays full width, and the
parity bar goes unmet rather than the product decision being reversed.**

Cost, measured: overview reads **0.842**; `max-width: 1280px; margin: 0 auto` on
`.ov-scroll` takes it to **0.996** and the fleet mean from 0.949 to 0.960. No
other surface moves — `.ov-scroll` is the only container the design centres, and
`work`, `approvals` and `board` render full-width in the design too. A
sixteen-agent sweep of the eight surfaces still short of parity found no other
actionable drift, so this is the only lever that exists.

### Keepers — resolved: `.chip` named two different components

The design uses `.chip` for the suggestion chip: a 13px pill with 8px/13px
padding that wraps. The dashboard's L0 `primitives.css` used `.chip` for a mono
badge with a fixed `height: 18px`. The kit loads last and won on padding and
type while inheriting the badge's `display: inline-flex`, `align-items`, `gap`
and fixed height — 21px of content in a 16px box, sixteen occurrences.

The badge is `.tag-chip` now. It takes the new name because the design owns
`.chip` in the skin's vocabulary, and because it is the smaller move:
`ide-shell.ts` is its only renderer, and the `.chip.k-*`,
`.v2-overview-alerts .chip` and `.ide-plane-statusbar-meta .chip` rules that
came with it have no renderer at all. `components/v2/primitives-v2.ts` also had
a `SuggestionChip` rendering the design's `.chip`; nothing imported it, and it
is gone. The live suggestion chip is `components/common/suggestion-chip.ts`,
whose metrics are now the design's.

keepers went **0.848 → 0.909** on that. What is left is the button font metric
described under "the prototype ships no CSS reset": `.cf-view`, `.tasktag` and
the top-bar attention chips each stand 2–3px taller than the mock because
`line-height: normal` resolves against Noto Sans KR's metrics rather than
Arial's. Substituting a numeric leading was measured and rejected — it inherits
into the grid cells and cost the fleet 8.7pp.

### Board — resolved: the kit had dropped `.bd-stateblock`, not the design

The design's board renders a state-transition post (`Running → Overflowed`,
context 100%, `restart` pending) as a `.bd-stateblock`, reading three fields off
`post.stateBlock`. `BoardPost` in `types/core.ts` has no counterpart, so the
dashboard does not build the component — and that still holds; inventing the
fields to draw it would be the fake *mark-don't-fake* exists to prevent.

What did not hold is the conclusion I drew from it: that the kit should therefore
not carry the four CSS rules either. The kit is a vendored copy of the design's
stylesheets, and a copy that leaves rules out cannot be diffed against its
source. I had filed the omission under the repo's dead-surface policy;
`audit-dead-surface.py` audits OCaml modules and `.mli` exports and does not
mention CSS. Vendored now, in place.

board went **0.853 → 0.996**. The component is still unbuilt, and the stylesheet
is ready for the day the fields exist.


### Monitor — resolved: the roster grid had six tracks, the design has five

The live row carries a `.fl-runtime` cell between context and recent-tool that
the mock's row has no counterpart for, and its action group is three text buttons
(멈춤/깨움/종료) rendering ~156px, so the last track needs 160px. That six-track
value used to live in the shared `--fl-cols`, which laid the design's five cells
into six tracks and pushed every column wide.

`keeper-v2/fleet.css` carries the design's five tracks now, and
`v2-monitoring.css` restates six for `.v2-monitoring-surface` alone, bounded to
the widths above the shed-a-column tier so that tier keeps its own set. The live
roster still renders six cells in six tracks with a 160px action cell and no
overflow.

monitor went **0.928 → 0.995**.

### IDE — resolved: the rail tabs had two names

The live rail tabs rendered `.ide-v2-rail-tab*`; the design draws the same
component as `.ide-rail-tab*`, and the design's rules were never vendored, so the
tabs fell back to the generic button chrome. The component uses the design's
names now, `keeper-v2/surfaces.css` owns its type, spacing and selected state,
and `ide-v2.css` keeps only what the mock never had to solve: three tabs sharing
a 320px rail without wrapping, and a label that truncates instead of pushing its
neighbours out. `flex: 0 1 auto` rather than `1 1 0`, so a tab sizes to its label
the way the design draws it and still shrinks under pressure.

ide went **0.935 → 0.995**.

### Work — resolved the same way, plus the design's own note rule

`#29300` rebuilt the Work goal detail while this sync was in flight. The expanded
card used to print one undifferentiated strip of mono chips, including a
completion percentage that read 100% for a goal no evaluator had ever measured;
it is now four labelled sections built around the declared completion criteria,
and the prototype's `.wk-note` strip is gone with it. Nothing here should be
pulled back toward the prototype.

The 26px this cost on the parity page was not that, though, and the entry used to
say it was. The parity page renders **the design's DOM** — a markup change in the
dashboard cannot appear there at all. What appeared was `.wk-note` rendering with
no padding, border or margin, because the kit had dropped the rule when the
component lost its consumer. Same omission as board.

`work-v2.css` also carried two additions the design does not draw: a pill on
`.wk-bl-goal`, and five rules restating the segmented control as an
accent-filled pill under `.wk-viewseg` — which has no consumer anywhere in src.

work went **0.891 → 0.975**.

### Prompt book — `.pb-src-chip` takes its mono face from CSS, not markup

The design's `prompt-book.jsx` emits `className: 'pb-src-chip mono'`, so the
design's own stylesheet never sets a font on `.pb-src-chip`. The live
`prompt-book-panel.ts` emits bare `pb-src-chip`, and rather than teach the
component a second class the vendored `keeper-v2/prompt-book.css` compensates
in place: `.pb-src-chip` carries `font-family: var(--font-mono)` where the
prototype's rule does not. Deliberate one-line divergence from the verbatim
copy, recorded 2026-08-23 so a future re-sync does not "fix" it back.

### Systemic: the dashboard breaks Korean text properly and the mock does not

`app-shell-v2.css` and `styleseed-base.css` set `word-break: keep-all`, which is
what Korean prose needs — a word should not be split across lines. The prototype
sets it only locally, on code blocks, so its paragraphs break mid-word: the lab
lede reads `…같은 컴포넌트 라이브` / `러리를…` there and `…같은 컴포넌트` /
`라이브러리를…` here.

The element is otherwise identical on both sides — same font, same 12px, same
519.781px measured box. Only the break point moves, and every line after it
shifts. That is most of what separates lab-performance (0.935) from the rest of
Lab, whose other four sections sit at 0.986-0.996.

Nothing to fix. Matching the mock would mean splitting Korean words.

### schedule and lab-performance: what the numbers turned out to be

Both were open questions in this file and neither is new drift.

schedule's conformance is 95.4%, the lowest measured, and 160 of its 244
mismatches are one thing: the surface is built out of bare `<button>` elements —
`.sch-poll-card`, `.sch-ev`, the cadence chips — which in the prototype keep the
UA `font: 13.333px Arial` and `color: buttontext`. That last one computes to pure
black on `.sch-ev-body` and `.sch-poll-top`; it does not show, because the design
colours the children, but it is counted. The dashboard's reset makes those
buttons inherit, which is what the design system specifies.

lab-performance is the same reset on the nav items plus the line-breaking above.

### Systemic: the prototype ships no CSS reset

The prototype's `<button>` elements keep the UA metrics — `Arial`, 13.333px,
`line-height: normal` — while its body copy runs at 1.55. Every dense chrome the
design builds out of buttons is sized by that leading.

Two halves, decided separately:

- **Leading is reproduced.** `craft-v2.css` restores proportional leading on the
  v2 shell's buttons, in a layer so a component that states its own leading keeps
  it. Without it a log row measured 41.7px against the design's 38.0px and the
  drift compounded down every list. This is what took the fleet mean from 0.815
  to 0.875 in one change.
- **Square edges are reproduced, per component.** `tokens.css` gives every button
  a 3px radius, and 1,309 of the dashboard's 1,783 buttons want it. Thirteen do
  not: rows and segments the design leaves square because they sit inside a
  container that already owns the corner. Those are named in `craft-v2.css`
  rather than dropping the default the other 1,309 depend on.
- **The body face is the same one, everywhere now.** Both sides load the real
  faces. The prototype resolved `styles/fonts/` TTFs (gitignored, filled by
  `scripts/fetch-v2-fonts.sh`) and its Google `@import` was dead until
  2026-08-23 — an `@import` after a rule is dropped by the CSS parser, so
  EB Garamond / JetBrains Mono / Share Tech Mono never loaded and the
  prototype rendered them from system fallbacks; the harness was measuring the
  fallback, not the design. The import now sits above the first rule. The
  dashboard serves the same bytes the harness browser would fetch itself:
  latin woff2 subsets in `fonts.css` and Noto Sans KR as 124 unicode-range
  slices in `fonts-noto-sans-kr.css` (the browser fetches only the 3-6 slices
  a screen hits, ~150KB, so the no-9.9MB-TTF rule's intent survives). Width
  triangulation returns identical metrics on both pages on any machine.
  Mean after both fixes: **0.9527** (was 0.9621 when both sides rendered
  fallbacks — the higher number measured the accident, not the design). Logs
  and board return to 0.995/0.986. The monitor delta (0.864) is view-state,
  not skin: the `.sigil` rules are byte-identical and the 30px/46px readings
  that chase each other across the diff come from two different components
  (`fleet.jsx:93` rail vs `fleet.jsx:252` detail) a naive leaf diff keys
  together by their shared text.

- **The font fallback is not.** Matching the design's `Arial` on buttons would
  put Korean UI text through a Latin fallback, and the design system's own
  specification names Noto Sans KR for chrome. The dashboard's normalisation
  stands; it costs a few pixels of width on the attention chips, which is why the
  top bar reads 0.916 on every surface.

## Full-app comparison

`live` shots taken from the running dashboard against the same prototype pages
score a mean of ~0.64. That number is **not a regression metric**: it moves with
whatever the backend is doing at the time (two runs 90 minutes apart differed by
1.5pp with no CSS change between them). It is useful only as a smoke test that
the app still renders.
