# RFC 0007 — Toast / Notification Manager

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-29
- **Depends on**: RFC 0001 (Headless Foundation — `PortalManager`,
  `IdGenerator`)
- **Independent of**: RFC 0003 (Roving Tabindex), RFC 0005 (Menu).
- **Blocks**: agent action feedback (Stage 4 spec §5.4), error UX
  consistency

---

## 1. Motivation

The dashboard signals async work outcomes via ad-hoc patterns:

- Composer "sent" → inline green badge (no auto-dismiss).
- Keeper spawn failure → console.error only (user invisible).
- Board comment posted → no feedback at all.
- Agent task complete → buried inside the live log feed.

The result is two failure modes:

1. **Silent success / silent failure**: users don't know if a click
   landed.
2. **Inconsistent dismiss**: when feedback exists, some require a
   manual close, some auto-disappear, some block scroll.

This RFC defines a singleton `ToastManager` that owns a queue of
notifications, each with its own `duration`, `priority`, `role`
(`status` vs `alert`), and dedup key. Consumers `notify(opts)` and
the manager handles render, queue ordering, hover-pause, and
auto-dismiss.

`ToastManager` is the only design-system primitive that is a true
singleton — all other primitives are instance-per-mount. The
singleton is required because the **toast portal layer is global** and
the dedup key needs cross-component visibility.

## 2. Non-Goals

- Render markup. Headless. Consumer owns the toast bubble DOM.
- Replace optimistic UI inline messages. Toast is for transient
  feedback; persistent state errors belong in inline forms.
- Replace the live log / activity feed. Logs are append-only
  history; toasts are ephemeral.
- Per-toast positioning. Toasts stack in a single anchor (default
  bottom-right). Multi-anchor is out.

## 3. Public API

### 3.1 Singleton

```ts
// headless-core/src/toast-manager.ts
export type ToastSeverity = "info" | "success" | "warning" | "error";

export interface ToastDescriptor {
  /** Optional explicit id; auto-generated via IdGenerator otherwise. */
  id?: string;
  /** Severity → ARIA role mapping (`error` → "alert", others → "status"). */
  severity: ToastSeverity;
  /** Headline text. */
  message: string;
  /** Optional body text. */
  description?: string;
  /** Optional action button. */
  action?: { readonly label: string; readonly onClick: () => void };
  /** ms; 0 = sticky (no auto-dismiss). Default by severity. */
  duration?: number;
  /** Cross-component dedup key. Identical key replaces (does not
   *  enqueue) the prior toast and resets its timer. */
  dedupKey?: string;
}

export interface Toast extends ToastDescriptor {
  readonly id: string;
  readonly createdAt: number;
  readonly state: "queued" | "visible" | "dismissed";
  readonly priority: number;  // derived from severity
}

export interface ToastManager {
  notify(toast: ToastDescriptor): string;  // returns id
  dismiss(id: string): void;
  dismissAll(): void;
  /** Pause auto-dismiss timers for hovered toasts. */
  pause(id: string): void;
  resume(id: string): void;

  getQueue(): ReadonlyArray<Toast>;
  subscribe(listener: (queue: ReadonlyArray<Toast>) => void): () => void;
}

export function getToastManager(): ToastManager;
```

### 3.2 Preact adapter

```ts
// headless-preact/src/use-toasts.ts
export function useToasts(): {
  toasts: ReadonlyArray<Toast>;
  notify: (descriptor: ToastDescriptor) => string;
  dismiss: (id: string) => void;
};

// helper for the toast region container (consumer renders inside
// usePortal({ layer: "toast" }))
export function getToastRegionProps(): {
  readonly role: "region";
  readonly "aria-label": "Notifications";
  readonly "aria-live": "polite";
  readonly "aria-atomic": false;
};

// helper per toast item
export function getToastItemProps(toast: Toast): {
  readonly id: string;
  readonly role: "status" | "alert";
  readonly "aria-live": "polite" | "assertive";
  readonly "data-severity": ToastSeverity;
  readonly "data-state": "queued" | "visible" | "dismissed";
};
```

## 4. Severity → priority → role mapping

| Severity | Priority | Default duration (ms) | ARIA role | `aria-live` |
|---|---:|---:|---|---|
| `error` | 4 (highest) | 0 (sticky) | `alert` | `assertive` |
| `warning` | 3 | 8000 | `status` | `polite` |
| `success` | 2 | 5000 | `status` | `polite` |
| `info` | 1 (lowest) | 5000 | `status` | `polite` |

Higher priority renders first. `error` defaults to sticky because
errors usually require a user response (retry / report); consumer can
override with explicit `duration`.

## 5. Queue & dedup semantics

- **Max visible**: 5 (configurable via env constant). When 6th
  arrives, the lowest-priority oldest visible toast is preempted into
  `state: dismissed`.
- **Queued vs visible**: anything beyond max-visible enters queue and
  promotes when a slot frees.
- **Dedup**: identical `dedupKey` replaces the prior matching toast
  *in place* (preserves slot, resets timer, updates message). Without
  `dedupKey`, every notify creates a distinct toast.
- **Order**: priority desc, then `createdAt` asc. Promotes from queue
  via the same ordering when slots free.

## 6. Hover pause / focus pause

- **Hover-pause**: when the user's pointer enters a toast, its
  duration timer pauses. On leave, timer resumes from the elapsed
  point (not restarted).
- **Focus-pause**: same semantics for keyboard focus. A user who
  Tabs into the toast region (e.g., to click an action) doesn't
  watch toasts disappear under them.
- **Region-pause**: hovering anywhere over the toast region pauses
  *all* visible timers, not just the hovered one. Standard pattern
  for stacked notification regions (Sonner / Radix Toast).

## 7. Action button semantics

When `action` is set, the toast is **not** sticky-by-default for
errors. The action button is the user response, and the timer ticks
normally. Pressing `Enter` while the action button is focused
invokes `onClick` and dismisses the toast immediately.

If the user clicks anywhere on the toast body but not the action,
the toast does **not** dismiss — the body is non-interactive.

## 8. Accessibility

- Region container gets `role="region"` + `aria-label="Notifications"`
  + `aria-live="polite"` so screen readers know the region's
  purpose without announcing every minor change.
- Each toast item carries its own `aria-live` (`polite` or
  `assertive`). Putting `aria-live` on the region alone causes
  inconsistent announcements when items are added with different
  severities.
- `aria-atomic: false` so only the new item is announced, not the
  whole region on each addition.
- Errors as `role="alert"` interrupt the screen reader's current
  speech. Standard convention.
- Reduced motion: `data-state` transitions; primitive does not
  enforce CSS — consumer's responsibility.

## 9. Test plan

`headless-core/src/toast-manager.test.ts`:

1. **Notify and visible** — first notify becomes `state: visible`,
   `getQueue()` reflects it.
2. **Auto-dismiss** — after `duration`, state flips to `dismissed`,
   subscribers fire.
3. **Sticky** — `duration: 0` never auto-dismisses.
4. **Dedup replace** — second notify with same `dedupKey` replaces
   prior and resets timer.
5. **Priority order** — `error` enqueued after `info` renders first.
6. **Max visible cap** — 6th notify queues; 1st auto-dismiss promotes
   queue head.
7. **Preempt low-priority** — `error` arriving when 5 `info` are
   visible preempts oldest `info` immediately, not via queue wait.
8. **Hover pause / resume** — `pause(id)` then 1 s wait then
   `resume(id)` → toast remains visible an additional `duration - 1s`.
9. **Action click dismisses** — invoking `action.onClick` immediately
   transitions to `dismissed`.
10. **`dismissAll`** — flips every visible toast to `dismissed` in
    one subscriber callback.
11. **`getToastItemProps`** — severity → role + `aria-live` mapping
    matches §4.
12. **`getToastRegionProps`** — region attributes invariant.

`headless-preact/src/use-toasts.test.tsx`:

13. **Hook reactivity** — Preact re-renders when subscriber fires.
14. **Region layer** — consumer rendering inside
    `usePortal({ layer: "toast" })` sits above modals (z-index
    `--z-toast` = 100).

`jest-axe` runs against region with 0, 1, and 5 toasts.

## 10. Migration path

Consumer migrations (separate PRs):

1. **Composer "sent" feedback** — replaces inline green badge.
2. **Keeper spawn failure** — surfaces the silent error.
3. **Board comment posted** — adds the missing feedback.
4. **Agent task complete** — toast for terminal-state events; live
   log keeps full history.

## 11. Merge criteria

- [ ] `headless-core/src/toast-manager.ts` lands
- [ ] All 12 core tests + 2 hook tests pass under `vitest --run`
- [ ] `jest-axe` passes on 3 region states (0/1/5 toasts)
- [ ] `headless-preact/src/use-toasts.ts` lands
- [ ] One consumer migrates as proof-of-pattern (Composer "sent"
      recommended — high visibility, low risk)
- [ ] CHANGELOG entry under v0.5
- [ ] No toast chrome tokens leaked into this PR (token follow-up
      Stage 1.4)

## 12. Open questions

1. **Max visible default** — 5 vs 3. APG does not prescribe; 5
   matches Sonner's default which most operators have muscle memory
   for, 3 is more conservative.
2. **`error` default sticky** — should `error` *with* `action`
   stay sticky to force a response? Current proposal says no
   (action is the response signal). Confirm.
3. **Region anchor** — bottom-right is the v1 default. Is bottom-
   center or top-right needed? Defer; primitive does not bind
   anchor — consumer chooses.

These do not block draft acceptance but must close before the
implementation PR opens.
