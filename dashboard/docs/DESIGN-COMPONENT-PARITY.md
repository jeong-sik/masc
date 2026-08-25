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

## Where it stands (2026-08-24 re-measure)

**2019 of 2433 design components implemented — 83.0%** (baselines: 55.2% / 1344
on 2026-08-22, 57.4% / 1398 on the first 2026-08-23 re-measure, 82.4% / 2006 on
the second). The vendored kit
is the mirror image: at the 57.4% mark, 42% of its 2870 selectors (1216) styled
nothing in the app; each component build below activates rules that were already
vendored.

`lanes.css` used to be the shape of the problem — a correct stylesheet for a DOM
the app did not render. That is closed: lanes, messages, molecules,
monitor-more, dock and app now sit at 100%, and every surface below 60% carries
its reason in this file or in the component header (no live signal, or a
deliberate rename the design itself superseded).

| Design file | Implemented | |
|---|---|---|
| palette | 100.0% | 16/16 — rebuilt on the design's `cmdk-*` markup 2026-08-24 (ninja-keys removed) |
| data-surfaces | 11.1% | 1/9 |
| toast | 12.5% | 1/8 |
| organisms-5 | 37.0% | 10/27 — `kc-*` drawer; superseded by the design's own fullscreen keeper-config |
| keepers | 55.6% | 10/18 |
| registry | 59.0% | 69/117 — remainder is persona CRUD / keeper-create wizard, no live API |
| rails | 62.4% | 103/165 |
| ide | 63.2% | 24/38 |
| tweaks-panel | 69.6% | 16/23 |
| fleet | 74.5% | 108/145 — remainder is 실행 슬롯 WFQ band, no slot/weight telemetry |
| lab | 75.0% | 30/40 |
| runtime-editor | 78.1% | 75/96 |
| connectors | 78.6% | 44/56 |
| work | 78.6% | 151/192 — remainder needs assign-to-keeper / task-create / gate-outcome APIs |
| board | 81.8% | 36/44 |
| settings | 82.0% | 73/89 |
| approvals | 82.8% | 77/93 |
| fusion | 84.4% | 114/135 |
| shell | 84.9% | 45/53 |
| overview | 86.8% | 59/68 |
| memory | 87.9% | 58/66 |
| schedule | 91.2% | 135/148 |
| verify-queue | 91.3% | 63/69 |
| command | 94.1% | 32/34 |
| internal-agents | 94.3% | 33/35 |
| journey | 94.3% | 50/53 |
| turn-inspector | 94.6% | 53/56 |
| composer | 94.9% | 37/39 |
| keeper-config | 97.5% | 119/122 |
| logs | 97.1% | 34/35 |
| app, dock, lanes, messages, molecules, monitor-more | 100% | |

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
| Command palette | its own `cmdk-*` markup, 16 components | Rebuilt onto that markup 2026-08-24 (`common/command-palette.ts`, replacing `ninja-keys`), 16/16 with the design's deep search — goals, tasks, Gate approvals, fusion runs, board posts, connectors — over live signals. |
| Lane Queue | 72 `dl-*` components | built 2026-08-23 (`components/lanes/`), 100% |
| Journey | 53 `ev-*` components | rebuilt 2026-08-23 (`components/v2/journey-v2.ts`), 50/53 — `jw-stim*` has no live signal |
| monitor-internal | `.ia-badge`, `.ai-table`, `.ai-strip` — a named vocabulary | Rebuilt onto that vocabulary 2026-08-23 (`internal-agents-monitor.ts`); 94.3% (33/35) |
| lab | — | Tailwind utilities assembled inline. A vendored stylesheet cannot reach a surface with nothing named to style. |
| Verify queue | 69 `vq-*` components | built 2026-08-23 (`components/verification/verify-queue.ts`), 63/69 |

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
