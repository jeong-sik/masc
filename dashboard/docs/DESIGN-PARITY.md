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
| `design-parity-gaps.mjs [name…]` | selectors the design defines that the vendored kit does not |
| `design-parity-leaks.mjs` | selectors owned by both a legacy sheet and the kit, and the geometry the kit does not restate |

`design-parity-ssim.mjs` computes SSIM itself (11×11 gaussian, σ=1.5, Wang et al.
2004) over grayscale planes from ImageMagick. ImageMagick's own
`compare -metric SSIM` reports the identical number for SSIM and DSSIM in 7.1.2,
so it is not used for the metric.

The harness writes `prototypes/keeper-v2/_parity/` and `_parity-vendored.html`;
both are gitignored and regenerated.

## Where it stands (2026-08-22, `Keeper Agent v5.html`, 1600×1000)

| Surface | SSIM | | Surface | SSIM |
|---|---|---|---|---|
| logs | 0.996 | | registry | 0.955 |
| connectors | 0.986 | | schedule | 0.944 |
| lab | 0.986 | | ide | 0.935 |
| fusion | 0.978 | | monitor | 0.928 |
| command | 0.969 | | keepers | 0.909 |
| approvals | 0.966 | | work | 0.891 |
| | | | board | 0.853 |
| | | | overview | 0.842 |
| | | | **mean** | **0.939** |

Nine of the fourteen sit at 0.93 or above and seven at 0.95 or above. The four
that do not — overview, board, work, monitor — are each held there by one named
cause, ledgered underneath, and none of the four is skin drift. **Across the ten
surfaces where the two sides agree on structure the mean is 0.962**; that is the
figure to read as "does the skin match". The 0.939 fleet mean includes the four
and is the figure to read as "how close is the whole dashboard to the mock".

Style conformance — `getComputedStyle` compared property by property across every
classed element on ten surfaces — is **96.89%** (41,182 of 42,504 declarations),
from 85.85% before this pass. The largest remaining group is `font-family` (263),
which is the UA fallback the dashboard deliberately does not reproduce (see
below); without it the figure is 97.6%.

`settings` is not measurable: the prototype's `SURFACES` registry has no entry for
it, so `?surface=settings` is rejected and the page renders keepers.

## Divergence ledger

Every surface below 0.94 is held there by something that is not skin drift. Each
entry names what it is, why it stands, and what it costs.

### Overview — the surface is full-width, the design centres it at 1280px

`keeper-v2/surfaces.css` carries an explicit note: *"OVERRIDE (intentional
divergence from prototype): full-width, left-aligned … per design direction the
dashboard fills the content area to match the other surfaces
(board/monitoring/command/lab/ide). Do not re-add max-width / margin:auto on a
prototype re-sync."* The design still centres it in v5, and the note predates
this design drop, so it was put to the operator on 2026-08-22 with the
measurement — the decision is to keep full width.

Cost: overview measures **0.842**; restoring `max-width: 1280px; margin: 0 auto`
takes it to **0.996**, and the fleet mean from 0.939 to 0.950. No other
surface moves — `.ov-scroll` is the only centred container, and `work`,
`approvals` and `board` render full-width in the design too.

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

keepers went **0.848 → 0.909** on that. What is left is the roster and thread
chrome, where the residual is the button font fallback described below.

### Board — `.bd-stateblock` is a design component the dashboard has not built

The design's board renders a state-transition post (`Running → Overflowed`,
context 100%, `restart` pending) as a `.bd-stateblock`. The class appears nowhere
in `dashboard/src`. Vendoring the four rules would move the number without
changing anything the app renders, which is the fake this repo's *mark-don't-fake*
rule exists to prevent. Not vendored.

Cost: the second mock post is 56px shorter, and every post below it shifts.
board measures **0.853**.

### Monitor — the roster grid has six tracks, the design has five

`--fl-cols` in `keeper-v2/fleet.css` carries the local contract: *"Last track =
action cell (멈춤/깨움/종료): the 3 text buttons render ~156px, so the track must be
wide enough or the button group overflows left into the context value."* The
live row has an action cell the mock row does not, so the vendored grid has six
tracks against the design's five. The v5 width refinement (state 140→152,
context minmax 108→96) is merged into it.

Cost: on the parity page the prototype's five cells are laid into a six-track
grid, so every column lands wide of the design. monitor measures **0.928**.

### Work — the dashboard moved past the design here

`#29300` rebuilt the Work goal detail while this sync was in flight. The expanded
card used to print one undifferentiated strip of mono chips, including a
completion percentage that read 100% for a goal no evaluator had ever measured;
it is now four labelled sections built around the declared completion criteria,
and the prototype's `.wk-note` strip is gone with it.

The v5 export predates that, so the design still draws the old strip. This is the
design being behind the dashboard, not the dashboard drifting from the design —
nothing here should be pulled back toward the prototype. The claimable-backlog
double-inset fixed in this pass is separate and still holds (the backlog measures
identically to the design).

Cost: the goal detail is ~26px shorter than the mock's per open goal, so every
goal below the first sits high. work measures **0.891**, down from 0.965 before
`#29300` landed.

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
