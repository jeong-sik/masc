# headless-solid — SolidJS Adapters

> Status: PoC (RFC 0017, PR #1).

SolidJS adapter layer over the framework-agnostic `headless-core/` primitives. Mirrors `headless-preact/` one-to-one. Production components migrate via the **Solid island** pattern (Solid subtree mounted inside the existing Preact app).

## Conventions

| Aspect | Preact adapter | Solid adapter |
|--------|---------------|---------------|
| Return shape | value (`tasks: ReadonlyArray<Task>`) | accessor (`tasks: Accessor<readonly Task[]>`) |
| Subscribe → re-render | `useState` bumpState in `useEffect` | `createSignal` write directly; lifetime tied to `createRoot` |
| Cleanup | `useEffect` return | `onCleanup(dispose)` |
| Memoized derived | `useMemo([deps])` | `createMemo(() => ...)` (deps tracked automatically) |
| Per-render counter | `useRef + bumpState` | `createEffect` with read |

## File layout

```
headless-solid/
  use-task-queue.ts        — RFC 0009 adapter (PR #1)
  use-task-queue.test.ts
  use-toasts.ts            — RFC 0007 adapter (PR #2, planned)
  use-portal.ts            — RFC 0001 adapter (PR #2, planned)
  ...
```

Each file is opt-in to Solid's JSX runtime via the per-file pragma:

```ts
/** @jsxImportSource solid-js */
```

The dashboard's global `tsconfig.json` keeps `jsxImportSource: "preact"` so existing components require no change.

## Authoring an adapter

1. Find the matching `headless-preact/use-*.ts`.
2. Replace `useState` → `createSignal` (returns `[get, set]`).
3. Replace `useEffect(() => { const dispose = manager.subscribe(...); return dispose }, [...])` with:
   ```ts
   const dispose = manager.subscribe(...)
   onCleanup(dispose)
   ```
4. Return `tasks` (the getter) directly — do NOT call it inside the adapter.
5. Mirror the Preact test scenarios. Each test wraps the adapter in `createRoot((d) => ...)` and calls `d()` in `afterEach`.

## Out of scope

- Production component migration — see PR #3+ trajectory in RFC 0017.
- Solid Stores (`solid-js/store`) — used only when a primitive needs deep reactivity.
- ESLint enforcement of import boundaries — added in PR #2.
