# RFC 0001 — Headless Foundation

| Field | Value |
|-------|-------|
| Status | Draft |
| Authors | dashboard-ds team |
| Created | 2026-04-28 |
| Source spec | `Kimi_Agent_디자인 시스템 설계/design_system_v2.agent.final.md` Ch. 1, 8 |
| Related | `dashboard/design-system/SPEC.md`, migration_guide_sec01.md |

## Context

`design_system_v2` (Apr 2026) introduces a Radix-style Headless UI architecture: behavior + accessibility separated from presentation, with state surfaced through `data-*` attributes that Tailwind v4 `data-[…]` selectors can style. The dashboard currently has zero Headless primitives — every interactive component (Drawer, Popover, Tabs, Toggle) reimplements focus trap, click-outside, ESC handler, and `aria-expanded` wiring inline. This RFC defines the minimum foundation needed to start the Strangler Fig migration described in `migration_guide_sec01.md`.

## Goals

- Establish a framework-agnostic core for focus management, portal stacking, and ID generation.
- Provide a Preact adapter so existing components can wrap legacy patterns inside Headless primitives without behavior change (Phase 0 of migration guide).
- Land the first 3 primitives (FocusScope, PortalManager, IdGenerator) as typed signatures + minimal impl + unit tests, NOT as feature-complete components.
- Establish the directory layout, data-attribute conventions, and test infrastructure that subsequent primitives (Button, Popover, Dialog, Tabs, Toggle) will plug into.

## Non-goals

- Implementing every primitive Radix UI ships. Scope is FocusScope, PortalManager, IdGenerator only.
- Migrating any existing component. Migration is RFC 0002+ (per `migration_guide_sec01` Phase 1+).
- Bonsai/OCaml adapter (deferred — `design_system_v2` Ch. 8.1.3, lower priority than Preact path).
- npm package publishing (`@masc/headless-*` from spec Ch. 8.4) — internal-only first.
- Compound Component sugar (`Object.assign(Root, { Trigger, Content })`) — left to per-primitive RFCs.

## Directory layout

```
dashboard/design-system/
├── headless-core/           # framework-agnostic, pure TS, no Preact import
│   ├── focus-scope.ts       # createFocusScope() — tabbable collection, trap, restore
│   ├── portal-manager.ts    # z-index stack, nested portal ordering
│   ├── id-generator.ts      # SSR-safe, deterministic IDs (per-tree counter)
│   ├── types.ts             # shared types: FocusableElement, PortalLayer, etc.
│   └── __tests__/           # happy-dom, no Preact runtime
├── headless-preact/         # Preact adapter, depends on headless-core
│   ├── use-focus-scope.ts   # hook wrapping createFocusScope
│   ├── use-portal.ts        # Preact Portal + PortalManager
│   ├── use-id.ts            # Preact useId() backed by IdGenerator (SSR fallback)
│   ├── as-child.ts          # cloneElement merging utility
│   └── __tests__/
└── RFC/
    └── 0001-headless-foundation.md  ← this file
```

**Why split core ↔ preact-adapter?** `design_system_v2` Ch. 8.1 calls for a future Bonsai adapter sharing the same focus management and portal logic. Splitting now is cheaper than refactoring later. The cost is one more directory; the win is testability (core tests run without preact runtime) and a documented boundary.

## First 3 primitives — API sketch

> NOTE: the snippets below are RFC-level sketches, not the merged implementation. Real types land in implementation PRs (RFC 0001-impl-1, -2, -3).

### `headless-core/id-generator.ts`

```ts
export interface IdGenerator {
  next(prefix?: string): string;
  reset(): void;
}

export function createIdGenerator(seed?: string): IdGenerator;
```

- Deterministic per-tree counter (`prefix-N`). Stable across SSR + hydration when seed matches.
- Replaces ad-hoc `Math.random()` ID patterns in current Drawer / Popover code.

### `headless-core/focus-scope.ts`

```ts
export interface FocusScope {
  activate(): void;        // capture current focus, install trap
  deactivate(): void;      // remove trap, restore prior focus
  focusFirst(): void;
  focusLast(): void;
  contains(el: Element): boolean;
}

export interface FocusScopeOptions {
  containerRef: () => HTMLElement | null;
  loop?: boolean;            // default true
  restoreFocus?: boolean;    // default true
  initialFocus?: 'first' | 'container' | (() => HTMLElement | null);
}

export function createFocusScope(opts: FocusScopeOptions): FocusScope;
```

- Tabbable collector: querySelector + element-visible filter (no `tabindex='-1'`, no `disabled`, not hidden).
- Trap: `Tab` / `Shift+Tab` cycles within container; outside-of-container focus pulled back.
- Restore: stash `document.activeElement` on activate; restore on deactivate.

### `headless-core/portal-manager.ts`

```ts
export interface PortalLayer {
  id: string;
  zIndex: number;
  layer: 'dropdown' | 'sticky' | 'overlay' | 'drawer' | 'modal' | 'toast';
}

export interface PortalManager {
  push(layer: PortalLayer): void;
  pop(id: string): void;
  topmost(): PortalLayer | null;
  layers(): ReadonlyArray<PortalLayer>;
}

export function createPortalManager(): PortalManager;
```

- Existing `tokens/source.ts` already defines 7-slot z-index raw tokens (`--z-base/sticky/dropdown/overlay/drawer/modal/toast`). PortalManager binds the `layer` discriminator to those tokens, keeping a single source of truth for stacking.
- Open question: do we need an additional `popover` layer for non-modal hover content, or does `overlay` suffice? Defer to RFC 0002 (Popover primitive).

## Data-attribute convention

Per `design_system_v2` §1.1.3, primitives surface state via `data-*` attributes only:

| Attribute | Values | Used by |
|-----------|--------|---------|
| `data-state` | `open` / `closed` / `entering` / `leaving` | Dialog, Popover, Drawer, Tooltip |
| `data-side` | `top` / `right` / `bottom` / `left` | Popover, Tooltip, Drawer |
| `data-align` | `start` / `center` / `end` | Popover, Tooltip |
| `data-pressed` | `true` / `false` | Button, Toggle |
| `data-focus-visible` | `true` / `false` | every focusable primitive |
| `data-disabled` | `true` (presence) | every interactive primitive |

Tailwind v4 `data-[state=open]:…` selectors consume these. No JS class swapping. This RFC does not enumerate every primitive's attributes — only the convention.

## Token bridge

Headless primitives never inline z-index, color, or duration values. They reference role-tier tokens via Tailwind utilities (`z-modal`, `bg-surface-primary`, `duration-motion-enter`). The `motion-enter / motion-exit` role tokens already exist in `tokens/source.ts:587-593`. Layer tokens already exist as raw tier (`tokens/source.ts:264-268`).

`design_system_v2` §4.2.3 proposes `--m-layer-*` namespaced tokens with 8 slots (adds `fixed`, `modal-backdrop`, `popover`). **This RFC does not migrate the namespace.** A separate RFC (0003 Token Layer Namespace) addresses that, since renaming touches 50+ CSS files.

## Migration strategy

Per `migration_guide_sec01` Phase 0–5 (13 weeks). This RFC implements Phase 0 (infrastructure) and unblocks Phase 1 (Chrome migration). Migration is opt-in per legacy component:

1. Existing component continues to work using inline focus / popover handling.
2. New PR replaces the inline handling with `useFocusScope` / `usePortal` from `headless-preact/`.
3. `data-state` attributes added; CSS bridge in `migration-bridge.css` (deferred to RFC 0002) keeps `.is-open` selectors working until all callers migrate.
4. Once all callers migrate, legacy CSS hooks are removed.

## Test strategy

| Layer | Tool | What |
|-------|------|------|
| Unit | vitest + happy-dom | createFocusScope tabbable collection, IdGenerator determinism, PortalManager ordering |
| Integration | vitest + happy-dom + preact | useFocusScope mounts / unmounts, useId SSR parity |
| a11y baseline | jest-axe (pending RFC 0001-c via Lane C) | each primitive ships an a11y test the moment its first impl lands |
| Visual | not in scope | snapshot infra is Phase 0 of migration_guide; tracked separately |

## Open questions

1. **Tabbable filter source of truth**: Radix uses `tabbable` package; React Aria has its own. Vendor in or ship our own filter? Recommendation: ship our own (≈80 LoC), zero new deps, matches WCAG 2.2 keyboard accessibility test we will run anyway.
2. **SSR**: dashboard is Vite + Preact SPA — currently no SSR. IdGenerator's SSR fallback is YAGNI today but cheap to keep optional. Ship the option; document as not-tested-without-SSR.
3. **Layer namespace migration**: do we keep `--z-*` raw tier and add `--layer-*` role tier as alias, or rename? Defer to RFC 0003.
4. **asChild semantics**: Radix vs React Aria differ on event handler merge order. Decide in RFC 0002 (first primitive that needs asChild).

## Acceptance criteria for this RFC

- [ ] Reviewer agrees with directory split (`headless-core` ↔ `headless-preact`).
- [ ] Reviewer agrees with the 3 first primitives + their API shape.
- [ ] Reviewer agrees with `data-*` convention table.
- [ ] Reviewer flags any conflict with existing `tokens/source.ts` layer tokens.

Once these are checked, RFC 0001 is accepted and 3 implementation PRs (-impl-1 IdGenerator, -impl-2 PortalManager, -impl-3 FocusScope) become unblocked.

## Stopping criteria for this RFC's implementation phase

Implementation is complete when:
- 3 modules under `headless-core/` ship with > 80% line coverage.
- 3 hooks under `headless-preact/` ship with happy-path + cleanup tests.
- One existing component (Topbar branch popover, simplest case) is migrated end-to-end as proof of concept.
- All checks green; visual diff zero (per migration_guide §A.7 rollback trigger).

Out of scope for the implementation phase: every other primitive (Button, Dialog, Popover, Tabs, Toggle), Bonsai adapter, npm publish, Figma sync.
