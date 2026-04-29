# RFC 0006 — Tooltip

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-29
- **Depends on**: RFC 0001 (Headless Foundation — `PortalManager`,
  `IdGenerator`)
- **Independent of**: RFC 0003 (Roving Tabindex). Tooltips do not
  contain focusable items.
- **Blocks**: spec §5.4.3 InlineSuggestion (uses Tooltip for shortcut
  hints), keyboard discoverability work

---

## 1. Motivation

The dashboard has hover hints scattered across consumers. Each binds
its own `mouseenter` / `mouseleave` / `focus` / `blur` handlers, owns
its own `setTimeout` for the show delay, and renders its own absolute-
positioned div near the trigger.

The duplication produces:

- **Inconsistent show/hide delay** — some show instantly (visual
  flash), some never hide on blur.
- **No `aria-describedby` linkage** — screen-reader users get nothing.
- **No portal layering** — tooltips clip under sticky chrome or
  drawers.
- **No "one-at-a-time" guarantee** — hovering quickly between two
  buttons leaves both tooltips visible.

This RFC defines a single `createTooltip` controller plus a
`createTooltipManager` registry that enforces one-at-a-time, both
atop the existing `PortalManager` `dropdown` layer.

## 2. Non-Goals

- Render markup. Headless. Consumer owns DOM (the tooltip bubble).
- Floating UI / Popper-style collision math. The first cut delegates
  positioning to consumer (CSS `position: absolute` near the trigger).
  A follow-up RFC adds collision flip if needed.
- Rich interactive content inside the tooltip. Tooltips are
  read-only short text. Anything interactive should be a Popover
  (out of scope here).

## 3. Public API

### 3.1 Core

```ts
// headless-core/src/tooltip.ts
export interface TooltipOptions {
  /** ms before showing on hover/focus. Default: 300. */
  showDelay?: number;
  /** ms before hiding on leave/blur. Default: 0 (immediate). */
  hideDelay?: number;
  /** Initial placement hint; consumer applies via CSS or popper. */
  placement?: "top" | "bottom" | "left" | "right";
  /** Controlled mode: parent owns isOpen state. */
  open?: boolean;
  /** Fires on open/close. */
  onOpenChange?: (open: boolean) => void;
}

export interface TooltipController {
  readonly isOpen: boolean;
  readonly id: string;  // for aria-describedby

  // Imperative
  show(): void;
  hide(): void;

  // Event-based (consumer wires to DOM)
  handleTriggerMouseEnter(): void;
  handleTriggerMouseLeave(): void;
  handleTriggerFocus(): void;
  handleTriggerBlur(): void;
  handleTriggerKeyDown(e: { key: string }): void;  // Esc closes
  handleContentMouseEnter(): void;  // cancel hide timer
  handleContentMouseLeave(): void;  // restart hide timer

  // ARIA prop bundles
  getTriggerProps(): {
    readonly "aria-describedby": string | undefined;
    readonly onMouseEnter: () => void;
    readonly onMouseLeave: () => void;
    readonly onFocus: () => void;
    readonly onBlur: () => void;
    readonly onKeyDown: (e: KeyboardEvent) => void;
  };

  getContentProps(): {
    readonly id: string;
    readonly role: "tooltip";
    readonly "data-placement": "top" | "bottom" | "left" | "right";
    readonly "data-state": "open" | "closed";
    readonly onMouseEnter: () => void;
    readonly onMouseLeave: () => void;
  };

  subscribe(listener: (open: boolean) => void): () => void;
  destroy(): void;
}

export function createTooltip(opts?: TooltipOptions): TooltipController;
```

### 3.2 Singleton manager (one-at-a-time)

```ts
// headless-core/src/tooltip-manager.ts
export interface TooltipManager {
  /** Register a tooltip; subsequent open() calls dismiss the prior. */
  register(tooltip: TooltipController): () => void;  // returns unregister
  /** Force-close any open tooltip. Used on Esc / window blur. */
  closeAll(): void;
}

export function getTooltipManager(): TooltipManager;
```

The manager is a singleton. When tooltip A is open and tooltip B
calls `show()`, manager hides A first. Skip-window: 100 ms — if a
new `show()` arrives within 100 ms of the prior `hide()`, suppress
the prior's hide animation and let the new tooltip take over without
a flash.

### 3.3 Preact adapter

```ts
// headless-preact/src/use-tooltip.ts
export interface UseTooltipArgs extends TooltipOptions {
  /** Tooltip body content. Used to default `aria-describedby` content. */
  content: ComponentChildren;
}

export function useTooltip(args: UseTooltipArgs): {
  isOpen: boolean;
  triggerProps: JSX.HTMLAttributes<HTMLElement>;
  contentProps: JSX.HTMLAttributes<HTMLElement>;
  /** Render as a sibling inside a `usePortal({ layer: "dropdown" })` */
  show: () => void;
  hide: () => void;
};
```

## 4. Lifecycle

```
trigger:mouseenter ─┐
trigger:focus       ├─→ start showDelay timer
                    └  (cancel any pending hide timer)
                        on timer fire: isOpen=true, manager.notify()

trigger:mouseleave  ┐
trigger:blur        ├─→ start hideDelay timer
                    └  (cancel any pending show timer)
                        on timer fire: isOpen=false

content:mouseenter  ─→ cancel hide timer
content:mouseleave  ─→ start hideDelay timer

trigger:keydown(Esc) ─→ immediate hide (no delay)
manager.closeAll() ─→ immediate hide

destroy() ─→ cancel both timers, hide if open
```

`hideDelay: 0` matches W3C ARIA APG default for tooltips (immediate
hide on blur). 300 ms `showDelay` matches APG; reduce only with
explicit reason.

## 5. Accessibility

- Trigger element receives `aria-describedby="<tooltipId>"`. The id
  comes from `IdGenerator` (RFC 0001) so SSR/hydration are stable.
- Content element receives `role="tooltip"` and the matching `id`.
- Tooltip content **does not** receive focus. The trigger keeps focus.
- `Esc` while focused on the trigger closes the tooltip.
- `prefers-reduced-motion` is respected via `data-state` consumer
  CSS (no JS branch needed in the primitive).

`hideDelay: 0` ensures the tooltip cannot block click activation —
the trigger `click` handler fires after the tooltip has hidden because
hide is synchronous on `mouseleave`/`blur`, both of which precede
`click`.

## 6. Tokens (deferred to follow-up)

Tooltip chrome tokens (`--tooltip-bg`, `--tooltip-fg`,
`--tooltip-border`, `--tooltip-shadow`) are out of scope. They land in
the same Stage 1.4 token follow-up as Menu chrome tokens (see RFC
0005 §6).

In the meantime, consumers wire visible state through
`data-state="open"` / `data-state="closed"` and Tailwind v4 selectors.

## 7. Composition

```
trigger element
  │ aria-describedby=<id>  + 5 event handlers
  └──────────────────────────────────────────────
         ┊ onMouseEnter / onFocus
         ▼
   showDelay timer (300 ms)
         │
         ▼
   isOpen=true → manager hides any prior tooltip
         │
         ▼
   PortalManager.push(layer="dropdown")
         │
         ▼
   tooltip content
     id=<id> role=tooltip data-state=open
```

PortalManager `dropdown` layer is the same z-index as Menu dropdown.
Within that layer, the tooltip manager guarantees one-at-a-time so
two siblings cannot stack visually.

## 8. Test plan

`headless-core/src/tooltip.test.ts`:

1. **Show delay** — `handleTriggerMouseEnter` → 300 ms → `isOpen=true`.
2. **Hide delay 0** — `mouseLeave` → immediate `isOpen=false`.
3. **Hide delay non-zero** — `hideDelay: 200` → 200 ms gap.
4. **Cancel show on early leave** — leave before showDelay fires →
   `isOpen` never flips.
5. **Cancel hide on re-enter** — leave → re-enter content within
   hideDelay → tooltip stays open.
6. **Focus shows / blur hides** — keyboard parity with mouse.
7. **Esc immediate hide** — bypasses delays.
8. **Manager one-at-a-time** — A.show() then B.show() → A hides
   before B opens.
9. **Manager skip-window** — B.show() within 100 ms of A.hide() →
   no flash on A.
10. **`aria-describedby` linkage** — trigger references content id;
    content has matching id.
11. **`destroy` cleanup** — pending timers cleared, manager
    unregisters.
12. **Controlled mode** — passing `open: true` overrides timers.

`headless-preact/src/use-tooltip.test.tsx`:

13. **JSX render path** — content renders inside the portal layer,
    visible in DOM only when `isOpen`.
14. **`prefers-reduced-motion`** — content `data-state=open` allows
    consumer to skip transitions; primitive itself unchanged.

`jest-axe` runs against tooltip fixture (button + tooltip).

## 9. Migration path

Consumer migrations (separate PRs):

1. Topbar action bar buttons (currently no hints).
2. Composer toolbar shortcuts (`Cmd+K`, `Cmd+Enter`).
3. Keeper card status icons (idle/working/stalled meaning).
4. KPI strip cells (formula + reference window).

## 10. Merge criteria

- [ ] `headless-core/src/tooltip.ts` + `tooltip-manager.ts` land
- [ ] All 12 core tests + 2 hook tests pass under `vitest --run`
- [ ] `jest-axe` passes on tooltip fixture
- [ ] `headless-preact/src/use-tooltip.ts` lands
- [ ] One consumer migrates as proof-of-pattern (Topbar action bar
      recommended — high visibility, low risk)
- [ ] CHANGELOG entry under v0.5
- [ ] No tooltip chrome tokens leaked into this PR

## 11. Open questions

1. **Show delay tunability** — 300 ms APG default vs operator
   preference for 100 ms (denser keyboarding). Per-instance override
   supported via `showDelay`; question is whether we change the
   *default*.
2. **Focus-show suppression for click triggers** — buttons should
   show tooltip on hover but **not** on focus-after-click (would
   trigger every keyboard activation). Spec text says "focus shows" —
   confirm whether we add a `triggerFocusShows` opt-out.
3. **Multi-line content** — short prose ok; long prose / interactive
   should be Popover. Document the boundary.

These do not block draft acceptance but must close before the
implementation PR opens.
