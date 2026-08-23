# Component parity — does the dashboard render the design's components at all

`DESIGN-PARITY.md` measures the skin. It renders **the prototype's DOM twice** and
swaps only the CSS, which is what removes the data variable and makes SSIM mean
something. The cost of fixing the DOM is that DOM divergence becomes invisible:
a surface the dashboard rebuilt under different markup cannot lower that score,
because the parity page never renders the dashboard's markup. 0.9487 measures the
skin and only the skin.

This file measures the other half. It reads the dashboard's own source.

```bash
node e2e/design-parity-components.mjs           # design components the dashboard names
node e2e/design-parity-components.mjs --list fleet
node e2e/design-parity-orphans.mjs              # vendored CSS with no consumer
node e2e/design-parity-renames.mjs              # same component, different spelling
node e2e/design-parity-tokens.mjs               # var() that resolves to nothing
```

`design-parity-components.mjs` reads className literals out of the prototype's
JSX and asks whether the dashboard ever names each one. It reads source rather
than a rendered page on purpose: the rendered version
(`design-parity-vocab.mjs`, kept for spot checks) counts a badge only when some
keeper is blocked, so monitor read 52.8% on one run and 27.5% on the next, and
the *design* side moved too. Source is the same every time, and it reaches the
surfaces behind tabs and drawers that no click recipe covers.

## Where it stands (2026-08-22)

**1398 of 2435 design components implemented — 57.4%** (re-measured 2026-08-23; the 55.2% / 1344 figure is the 2026-08-22 baseline). The vendored kit is the
mirror image: **42% of its 2870 selectors (1216) style nothing in the app.**

`lanes.css` is the shape of the problem. The Lane Queue sub-view scores 0.959,
which reads as "the vendoring landed" — and not one `dl-` class exists anywhere
in `src`. The stylesheet is correct for a DOM the app does not render.

Orphan is not the same as wrong, though, and I got that backwards for a while.
The kit is a vendored copy of the design's stylesheets; a rule with no consumer
today is the copy being faithful, and is what makes the component buildable later
without re-deriving its CSS by hand. What `design-parity-orphans.mjs` measures is
therefore a fact about the app, not a defect in the kit: 42% of the design's
components have no markup on this side yet.

| Design file | Implemented | |
|---|---|---|
| palette | 0.0% | 0/16 |
| monitor-more | 3.8% | 2/52 |
| lanes | 5.6% | 4/72 |
| journey | 5.7% | 3/53 |
| internal-agents | 5.7% | 2/35 |
| registry | 10.3% | 12/117 |
| verify-queue | 11.6% | 8/69 |
| messages | 21.6% | 8/37 |
| lab | 27.5% | 11/40 |
| command | 32.4% | 11/34 |
| keeper-config | 36.9% | 45/122 |
| rails | 42.4% | 70/165 |
| fleet | 42.8% | 62/145 |
| molecules | 44.5% | 65/146 |
| … | | |
| logs | 97.1% | 34/35 |
| turn-inspector | 98.2% | 55/56 |
| dock, app | 100% | |

2026-08-23: `internal-agents-monitor.ts` was rebuilt onto the design's
`.ia-*`/`.ai-*` vocabulary, and approvals history was extended (decider pills
from the live `decision_source` field, `.ap-hist-reason` ← `decision_reason`,
Auto Judge summary stat). Every number on this page predates that work —
re-run the probes before quoting them.

## The gap is three different problems

`design-parity-renames.mjs` proposes 310 pairs where the dashboard looks like it
built the component and spelled it differently. **Those are proposals, not
findings.** Three of the families turned out to be genuine drift and two turned
out to be deliberate; the probe cannot tell them apart, and neither can a diff.
Each family needs its stylesheet's own stated reason read first.

### Drift — the component is the design's, the name is not

Renaming activates rules already in the bundle. Three are done:

| Family | Was | Result |
|---|---|---|
| turn inspector | every class was the design's name with a `k` in front (`kti-wf-row`) | `inspector.css` orphan 62% → 2%; coverage 31.6% → 98.2% |
| approvals history | `.ap-history-item`, a flex card, against the design's four-column `.ap-hist-row` | coverage 67.0% → 76.3% |
| IDE shell | `.ide-v2-*` transition scope kept after the transition | coverage 36.8% → 60.5% |

The turn inspector is the instructive one. Its stylesheet was a *faithful* port —
the comments cite the prototype by file and line, and it pins the same literals
where the repo's tokens differ. It was correct in every respect except the one
that decides whether the design's stylesheet reaches it.

approvals history moved again on 2026-08-23: the summary now follows the
design's stat strip (승인/거부/Auto Judge — the design's fourth slot, median
decision latency, has no live field and carries the live keeper count instead
of a fabricated number), the filter pills include the design's decider set
backed by the live `decision_source` field, and `.ap-hist-reason` renders the
audit record's `decision_reason` when the server recorded one. The 76.3%
above predates this; re-measured 2026-08-23: overall coverage is 57.4%
(1398/2435), internal-agents 88.6% (31/35).

### Deliberate — the different name is the point

Do not rename these. The reason is written in each stylesheet's header.

| Family | Why it stands |
|---|---|
| `kw-*` (keeper workspace) | A port that maps the design's raw palette onto the dashboard's token ladder — `--bg-deep` → `--color-bg-page` and so on, 221 `--color-*` references. Taking the design's names would let the kit's raw-palette rules win and undo the theming. Where a density rule is wanted the element already carries both names (`class="kw-kp-row kp-row"`). |
| `chat-block-*` | The design's names here are bare and generic — `.block`, `.count`, `.meta`, `.voice-row`, `.shell-title`. The dashboard uses bare `block` 194 times in chat alone. Adopting the design's vocabulary would collide across surfaces; namespacing was the better call. Reaching these needs a decision about which side moves, not a rename. |

### Not built — no markup for the skin to land on

| Surface | What the design draws | What the dashboard has |
|---|---|---|
| Command palette | its own `cmdk-*` markup, 16 components | `ninja-keys`, a third-party web component. None of the 16 can ever apply. |
| Lane Queue | 72 `dl-*` components | nothing; `lanes.css` is vendored anyway |
| Journey | 53 `ev-*` components | nothing |
| monitor-internal | `.ia-badge`, `.ai-table`, `.ai-strip` — a named vocabulary | Rebuilt onto that vocabulary 2026-08-23 (`internal-agents-monitor.ts`); re-measured 2026-08-23: 88.6% (31/35) |
| lab | — | Tailwind utilities assembled inline. A vendored stylesheet cannot reach a surface with nothing named to style. |
| Verify queue | 69 `vq-*` components | 8 |

## Tokens that resolve to nothing

`design-parity-tokens.mjs` is a third axis: styles that are wired to the right
component and still do nothing, because they read a custom property no one
defines. An undefined `var()` falls back to inheritance as a plain value, and
unsets the entire property inside `color-mix()` — invalid at computed-value time.
Neither reaches the console.

It proposes from source and confirms in the browser, because neither is
sufficient alone: Tailwind's theme defines `--text-sm` outside these files, and a
token the components set per element never appears on `:root`. It ignores
`var(--x, fallback)` — `work-v2.css` maps every `--volt*` to
`var(--color-volt*, var(--color-accent))` deliberately, and the fallback renders.

25 fallback-less references were confirmed dead; 29 declarations were repaired.
`--status-fail` alone accounted for ten, half of them inside `color-mix()`, so
Settings had been drawing failure states with no error border at all. 18 remain,
each needing its own decision rather than a mapping.
