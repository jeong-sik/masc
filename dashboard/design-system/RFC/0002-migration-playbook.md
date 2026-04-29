# RFC 0002 — Strangler Fig Migration Playbook

| Field | Value |
|-------|-------|
| Status | Draft |
| Authors | dashboard-ds team |
| Created | 2026-04-29 |
| Source spec | `Kimi_Agent_디자인 시스템 설계/migration_guide_sec01.md` |
| Depends on | RFC 0001 #11670 (merged) — Headless Foundation |

## Context

RFC 0001 landed the framework-agnostic core (IdGenerator/PortalManager/FocusScope) and Preact adapter (useId/usePortal/useFocusScope). With those primitives in main, every existing dashboard component that hand-rolls focus traps, click-outside listeners, ESC handlers, or aria-* wiring is a candidate for migration. This RFC defines **how** those migrations happen — the per-PR shape, ordering, verification, and rollback criteria — so each iter is mechanical rather than improvised.

The migration is **Strangler Fig** (per migration_guide_sec01 §A.2): existing components are wrapped, then their internals are replaced one consumer at a time. No big-bang rewrite. No long-lived branch.

## Goals

- Land each consumer migration as a **single, reviewable PR** that touches one component family.
- Maintain **zero visual regression** during the migration window. Snapshot tests are the gate.
- Keep production stable: any iter must be independently revertible without rolling back the foundation.
- Make the iter pattern boring enough that bots / autocoder agents can run it.

## Non-goals

- Re-styling. The migration is structural; visual changes go in separate PRs after the structure stabilizes.
- New features. A migration that introduces capabilities the legacy component lacked is split: migrate first, feature-add second.
- Rewriting the legacy CSS file before its consumer migrates. CSS lives until its last consumer leaves.

## Migration ordering

Components are migrated bottom-up (atom → molecule → organism → page). Earlier consumers in this list have fewer external dependencies.

| Iter | Component family | Headless primitive used |
|------|-----------------|-------------------------|
| 1 | Topbar branch popover | usePortal + useFocusScope |
| 2 | Topbar goal switcher | usePortal + useFocusScope |
| 3 | Topbar mode tabs | useId (for `aria-controls` between buttons and content) |
| 4 | Sidebar keeper select | useId (radio-group semantics) |
| 5 | Deck tabs | useId + roving-tabindex (RFC 0003 follow-up) |
| 6 | Confirm dialog | useFocusScope + usePortal (already partially uses DialogOverlay) |
| 7 | Drawer | useFocusScope + usePortal |
| 8 | Command palette | useFocusScope + usePortal + roving-tabindex |
| 9 | Resizable panel split | useMove (RFC 0004 follow-up) |
| 10+ | Tooltip / Popover library | usePortal + useFocusScope |

Iter 1 is the canonical reference. Each later iter follows the same shape.

## Per-iter PR shape

Every migration PR must include exactly these parts:

### 1. Replace inline lifecycle wiring

Drop the hand-rolled `useEffect + document.addEventListener` blocks that manage open/close, click-outside, ESC. Replace with the corresponding hook.

```ts
// before
const popRef = useRef(null)
const [open, setOpen] = useState(false)
useEffect(() => {
  if (!open) return
  const close = (e: MouseEvent) => {
    if (popRef.current && !popRef.current.contains(e.target as Node)) setOpen(false)
  }
  document.addEventListener('mousedown', close)
  return () => document.removeEventListener('mousedown', close)
}, [open])

// after
const popRef = useRef<HTMLDivElement | null>(null)
const [open, setOpen] = useState(false)
const portalId = usePortal({ layer: 'overlay' }).portalId
useFocusScope({ containerRef: popRef, active: open })
// click-outside: keep — it's UX choice, not lifecycle. Hook lifecycle
// is for activate/deactivate; outside-click is its own decision.
```

### 2. Surface state via `data-*` attributes

Per RFC 0001 §"Data-attribute convention": new code emits `data-state="open" | "closed"` on the visible surface. Tailwind v4 `data-[state=open]:…` selectors consume them.

```html
<div data-state={open ? 'open' : 'closed'} ref={popRef} class="...">
```

### 3. Add a focused unit test

The existing component test file gets one new case per migrated behavior:

- Open → focus moves into the scope (proxy: first tabbable becomes activeElement)
- Close → focus restores to the prior element
- ESC → calls the close callback
- Click outside → calls the close callback (if the component supports it)

These are mechanical. Reuse the helpers from `headless-preact/use-focus-scope.test.ts`.

### 4. Snapshot diff = 0%

Run the snapshot suite (or, today, manual screenshot comparison since visual regression infra is Phase 0 of migration_guide §A). If anything moved by even 1px, **stop and revert** — the migration is structural only.

### 5. Update one CSS hook at a time

Legacy CSS classes (`.is-open`, `.tb-branch-pop`) co-exist with new `data-state` selectors during the iter. Don't remove the legacy class until every consumer has migrated. The transition CSS file gets a single block per iter:

```css
/* migration-bridge.css — appended to per iter, removed in cleanup PR */
.tb-branch-pop[data-state='open'],
.tb-branch-pop.is-open { /* legacy + new */
  display: block;
}
```

### 6. PR description template

```
## Migration: <component> (Iter N)

Replaces inline focus / popover wiring with `useFocusScope` /
`usePortal`. Surfaces `data-state` so Tailwind data-[] variants can
style transitions. No visual change.

## Verification
- pnpm vitest run <test-files> → N+M passes (M = new behavior cases)
- pnpm tsc --noEmit clean
- Manual screenshot diff: 0px against pre-migration baseline

## Rollback
Single `git revert` of this PR. The headless-* primitives remain;
only this consumer reverts.
```

## Verification gates (per PR)

| Gate | Tool | Pass criteria |
|------|------|--------------|
| Type check | `pnpm tsc --noEmit` | clean |
| Existing component tests | `pnpm vitest run <file>` | no regression (count ≥ pre-PR) |
| New behavior tests | `pnpm vitest run <new-cases>` | added; pass |
| Manual snapshot | dev server + diff | < 0.5% pixel change |
| a11y test | jest-axe (if file already exists) | no new violations |

## Rollback criteria

Any one of these triggers an immediate revert:

- Snapshot diff > 0.5%
- jest-axe surfaces a new violation that wasn't present pre-migration
- Any test that was passing on main now fails
- Keyboard navigation regression (Tab cycle, focus restore, ESC)
- Performance regression > 20% on the component's render path (only if measured)

The revert is a single `git revert <pr-sha>` on the migration PR. The headless-core / headless-preact primitives stay in main — they're foundational and not affected by a consumer rollback.

## Iter cadence

- One iter per PR. No combining (e.g. "migrate Topbar branch popover AND goal switcher in one PR").
- Iter PRs target `main` directly, no feature branch chaining.
- Earlier iters block later iters in the dependency table (Iter 5 Deck tabs depends on RFC 0003 roving-tabindex; Iter 9 panel split depends on RFC 0004 useMove).

## Open questions

1. **Snapshot infra**: visual regression today is manual screenshot diff. Migration_guide §A.6 names Chromatic / Playwright as targets. This RFC assumes manual until a follow-up RFC lands the snapshot pipeline. Iters 1–3 can ship without it; iters 4+ should wait.
2. **Bridge CSS lifecycle**: when does `migration-bridge.css` get deleted? Proposal: when every consumer in the table above has migrated AND a `rg "is-open"` sweep returns 0. Tracked via a single GitHub issue updated per iter.
3. **AX (Agent Experience) components**: AgentPresence, HumanInTheLoop, AgentLifecycle from migration_guide §A.3 Phase 4 are net-new. They're not migration; they're additions. Out of scope for this RFC; covered by RFC 0005+.

## Acceptance criteria for this RFC

- [ ] Reviewer agrees with the iter ordering table.
- [ ] Reviewer agrees with the per-iter PR shape (6 sections).
- [ ] Reviewer agrees with the rollback criteria.
- [ ] Iter 1 (Topbar branch popover) is identified as the reference implementation.

Once accepted, Iter 1 PR can land and serve as the template for iters 2+.

## Related

- RFC 0001 (#11670, merged) — Headless Foundation
- migration_guide_sec01.md — original Strangler Fig walkthrough from the v2 spec
- design_system_v2 §1 (Headless Primitive Architecture)
- Future RFCs:
  - RFC 0003 — Roving Tabindex primitive
  - RFC 0004 — useMove primitive (resizable panels, drag handles)
  - RFC 0005 — AX (Agent Experience) components
