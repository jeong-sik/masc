# Dashboard `<Pill>` primitive convergence

Status: in progress (PR 1 landed the engine + StatusChip delegation)
Date: 2026-06-20
Scope: `dashboard/src/components/common` + feature components rendering tone pills
Related: `docs/design/keeper-v2-v12-gap-current.md`, keeper-v2 design ("v2" project)

## Context

The keeper-v2 gap analysis (2026-06-20) found the design's central primitive thesis — **one `<Pill>`
with a tone + a few variants** — unimplemented in the dashboard. Three competing badge primitives
coexist in `common/` with divergent tone enums, and ~66 forked `*Pill/*Badge/*Chip` definitions live
across feature components, including **two distinct same-named `StatusPill`** (`feature-health.ts`,
`harness-health-sections.ts`). Every keeper-v2 surface port re-rolls these atoms, so the divergence
compounds. This doc defines the converged `<Pill>` and the migration policy.

Why a doc and not an RFC: this is an additive, test-guarded design-system convergence with no
behavior change to existing callers. (The RFC-0270 slot is occupied by an unrelated open PR; we use a
design doc to avoid a numbering collision. Promote to an RFC if the team wants stronger authority.)

## The three existing primitives (two styling lineages)

| Primitive | Shape | Tone system |
|---|---|---|
| `status-chip.ts` (`StatusChip`, 33 consumers) | bordered tag, `border px-2 py-0.5 rounded-[var(--r-0)] text-[11px]` | inline Tailwind palette (`bg-success/10 text-success`) + raw passthrough |
| `badge.ts` (`CountBadge`, 6) | compact count, `px-1.5 py-px rounded-md tabular-nums` | inline Tailwind, distinct `default`/`accent` tones |
| `status-badge.ts` (`StatusBadge`, 8) | dot + label | `.status-badge` **CSS-utility class** (`.status-badge.ok`), NOT Tailwind palette |

StatusChip and CountBadge share the inline-Tailwind lineage; StatusBadge is a separate CSS-utility
lineage. A single class engine therefore converges the **StatusChip lineage** cleanly; CountBadge and
StatusBadge are reconciled separately (below) to avoid breaking their CSS/test contracts.

## `<Pill>` API (`common/pill.ts`)

```ts
type PillTone = 'neutral'|'ok'|'warn'|'bad'|'info'|'volt'|'paused'|'select'
interface PillProps { tone?, dot?, dotPulse?, uppercase?, mono?, soft?, class?, title?, testId?, children? }
pillClasses(tone, { uppercase?, mono?, soft?, extra? }) -> string   // pure engine
```

- Tones map to the bordered-chip palette; `volt` → the `--volt-dim/--volt-wash/--volt-strong` triple
  (`--volt-strong === --brand`), mirroring StatCell/Vital/settings-surface.
- A non-enum `tone` string passes through verbatim (raw Tailwind, e.g. a `verdictTone()` result).
- Variants: `uppercase` (default true), `mono` (FsmChip), `soft` (transparent ground — drops `bg-*`),
  `dot` (leading `bg-current` pip).
- `<Pill>` emits `data-pill*` attributes for testability, matching the pattern of the other primitives.

**Convergence invariant (tested):** `pillClasses(tone, { uppercase, extra })` is byte-identical to the
former `statusChipClasses(tone, extra, uppercase)`. `status-chip.ts` now delegates to `pillClasses`;
its public API, span, and 9 `data-status-chip-*` attributes are unchanged, so all 33 callers and the
existing test suite are untouched. Proven by `common/pill.test.ts` (`statusChipClasses === pillClasses`)
plus the unchanged `status-chip.test.ts`.

## Migration policy

**Use `<Pill>` for any new tone/status/badge span.** Do not add a new `*Pill/*Badge/*Chip` component or
inline `rounded-[var(--r-0)] border px-2 py-0.5 …` span for a tone indicator — render `<Pill tone=…>`.

Migrate the existing forks by family, one family per PR (each PR complete within its scope — no
partial/N-of-M migrations):

- **(a) Semantic status pills** (~8-12) → `<Pill>`. Headlines the two duplicate `StatusPill`,
  plus SnapshotBadge / PhaseBadge / KeeperPresencePill / RuntimeBadge / TraitPill(`soft`) / RolePill(`mono`).
- **(b) Count badges** (~6-8) and **(g) class-builder helpers** (~16-20) → route through the engine
  (a `count` variant is added to `pillClasses` when family (b) is migrated).
- **(e) Inline Tailwind pill strings** (~10-15) and **(d) tone-label domain badges** → `<Pill>` case-by-case.

**Keep distinct (NOT `<Pill>`):** `Sigil`/`SigilChip`/`KeeperBadge` (slot-color identity), `FilterChip`,
`LogFilter`, `SuggestionChip`, `IdPill`, `heartbeat-*-chip` — these are separate atoms, kept distinct in
the design too. Health-chip factory builders (`dashboard-shell.ts`) keep their structured
`DashboardHealthChip` shape; only the rendered span adopts `<Pill>`.

Collisions to resolve during migration: a local `Pill` in `connector-readiness-rail.ts` and
`connectorStatusPillClass/Label` in `connector-status.ts` → the canonical `common/pill.ts` `Pill`.

## Follow-ups (not in PR 1)

- **CountBadge** → delegate `countBadgeClasses` to a `pillClasses` `count` variant (straightforward;
  exact-class tests must stay green).
- **StatusBadge** → reconcile the `.status-badge` CSS-utility lineage with `<Pill dot>` (needs a CSS-token
  pass; deferred).
- **Re-fork guard** → a *principled* AST-based ESLint rule detecting the duplicated pill shape with an
  allowlist for the kept atoms. A name-based grep guard would false-positive on the kept atoms and reads
  as a string-classifier workaround, so it is intentionally deferred until it can be done by shape.

## Verification

- `pnpm test` — `common/{pill,status-chip,badge,status-badge}.test.ts` green; existing primitive tests
  pass unchanged (proves API + `data-*` preserved).
- `pnpm typecheck` clean; `<Pill>` renders in the Lab → Design Canvas "Pill (converged)" artboard.
