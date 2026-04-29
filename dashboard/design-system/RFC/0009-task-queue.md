# RFC 0009 — TaskQueue Manager

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-29
- **Depends on**:
  - RFC 0001 (Headless Foundation — `IdGenerator`)
  - RFC 0008 (AgentPresence — task → agent reference)
- **Blocks**: spec §5.4.1 TaskQueueVisualization consumer.
- **Sister to**: RFC 0007 (ToastManager). Both expose append-only
  event streams; TaskQueue is structured + queryable, Toast is
  ephemeral.

---

## 1. Motivation

MASC's coordination model issues *tasks* — units of work claimed by
one agent at a time, with priority, progress, and result. The
dashboard renders task state in three places today:

- **Goal verifier rail** — top-level goal task list.
- **Keeper card** — current task badge ("PK-12345 building").
- **Activity feed** — historical scroll of completed tasks.

Each renders from its own JSON snapshot (different cache TTLs, no
optimistic updates). The drift is visible at the user level — a task
shows `running` in one panel and `completed` in another for several
seconds. The activity feed has no a11y signal at all; SR users miss
every task transition.

This RFC defines a single `createTaskQueueManager` that owns the
canonical task list, exposes priority + state queries, and emits SR
announcements with the right urgency level for each transition.

## 2. Non-Goals

- Replace MASC's task storage. The manager mirrors, it does not
  author.
- Schedule tasks. Priority influences render order; the actual claim
  decision is server-side.
- Provide history beyond the in-memory window. Long-term task history
  belongs to a separate audit log surface.
- Support multi-assignee tasks (only one `agentId`). Multi-assignee
  is a follow-up RFC if MASC grows that pattern.

## 3. Public API

### 3.1 Core types

```ts
// headless-core/src/task-queue.ts
export type TaskState =
  | "queued"
  | "running"
  | "paused"
  | "completed"
  | "failed";

export interface TaskDescriptor {
  /** External id (e.g. JIRA ticket). Manager uses this as primary key. */
  readonly id: string;
  /** Owning agent id. Cross-references AgentPresenceManager. */
  readonly agentId: string;
  readonly title: string;
  readonly description?: string;
  readonly priority: number;  // higher = sooner
  readonly state: TaskState;
  /** 0..100 only meaningful while state="running". */
  readonly progress?: number;
  readonly startedAt?: string;   // ISO
  readonly completedAt?: string; // ISO
  readonly errorMessage?: string;
}

export interface Task extends TaskDescriptor {
  /** Manager-assigned creation timestamp; survives state changes. */
  readonly createdAt: string;
}
```

### 3.2 Manager

```ts
export interface TaskQueueOptions {
  /** Initial roster. */
  initialTasks?: ReadonlyArray<TaskDescriptor>;
  /** Bound for visible queue + history. Older completed/failed get
   *  evicted. Default 200. */
  maxRetention?: number;
}

export interface TaskQueueManager {
  // Roster
  add(task: TaskDescriptor): void;
  remove(id: string): void;
  update(id: string, patch: Partial<Omit<TaskDescriptor, "id">>): void;
  reorder(ids: ReadonlyArray<string>): void;  // explicit override

  // Queries (read-only views)
  getAll(): ReadonlyArray<Task>;
  byState(state: TaskState): ReadonlyArray<Task>;
  byAgent(agentId: string): ReadonlyArray<Task>;
  byPriority(): ReadonlyArray<Task>;  // queued + running, prio desc

  // Subscriptions
  subscribe(listener: (tasks: ReadonlyArray<Task>) => void): () => void;
  subscribeTask(id: string, listener: (task: Task) => void): () => void;

  // ARIA helpers
  /** Returns SR announce text + urgency level. */
  announceStateChange(
    id: string,
    prev: TaskState,
  ): { readonly text: string; readonly assertive: boolean };
}

export function createTaskQueueManager(
  opts?: TaskQueueOptions,
): TaskQueueManager;
```

### 3.3 Preact adapter

```ts
// headless-preact/src/use-task-queue.ts
export function useTaskQueue(manager: TaskQueueManager): {
  tasks: ReadonlyArray<Task>;
  byState: (state: TaskState) => ReadonlyArray<Task>;
};

export function useTask(
  manager: TaskQueueManager,
  id: string,
): Task | undefined;

export function useTasksForAgent(
  manager: TaskQueueManager,
  agentId: string,
): ReadonlyArray<Task>;
```

## 4. State transitions and announcements

| From → To | Announce text | Urgency |
|---|---|---|
| `*` → `queued` | (silent) | n/a |
| `queued` → `running` | "<title> started" | polite |
| `running` → `paused` | "<title> paused" | polite |
| `paused` → `running` | "<title> resumed" | polite |
| `running` → `completed` | "<title> completed" | polite |
| `running` → `failed` | "<title> failed: <errorMessage>" | **assertive** |
| `*` → `running` skipping queued | "<title> started" | polite |

`assertive` (failed) maps to `aria-live="assertive"` on the consumer
container; everything else uses `polite`.

## 5. Ordering policy

`byPriority()` orders queued + running tasks:

1. Higher `priority` first.
2. Within same priority: older `createdAt` first (FIFO among peers).
3. `running` tasks always above `queued` tasks of equal priority
   (they're physically active first).

`reorder(ids)` is an *explicit override* — consumers can drag-reorder
the visible list, and the manager respects that order until the next
priority change. Internal state still tracks the implicit ordering
for `getAll()` callers that don't care about UI order.

## 6. Progress semantics

- `progress` is meaningful only when `state === "running"`. The
  manager does **not** clamp; consumer is responsible for
  `Math.min(100, Math.max(0, p))` if they want to render an arc.
- Updates to `progress` while `state !== "running"` are accepted but
  ignored by the SR announce path (no announcement spam during
  start/finish transitions).

## 7. Retention

`maxRetention` (default 200) limits **non-active** tasks (`completed`
+ `failed`) in memory. When exceeded, the oldest completed/failed
task is evicted. Active tasks (`queued` / `running` / `paused`) are
never evicted.

Consumer wanting longer history queries the audit log surface (out
of scope here).

## 8. Test plan

`headless-core/src/task-queue.test.ts`:

1. **Add task** — `getAll()` includes it; subscribers fire once.
2. **Update state** — `running → completed` updates `completedAt`,
   subscribers fire, announce text matches §4.
3. **Failed announce assertive** — `running → failed` returns
   `{ assertive: true }`.
4. **Priority sort** — three tasks with priority 10 / 5 / 5 + mixed
   `createdAt`: priority-10 first, then priority-5 in FIFO.
5. **Running before queued at same priority** — running prio-5
   before queued prio-5.
6. **`reorder` override** — `reorder([id3, id1, id2])` reflects in
   `byPriority()` until next priority update; `getAll()` unaffected.
7. **Progress noop while paused** — `update(id, { progress: 50 })`
   on a paused task does not trigger announce.
8. **`subscribeTask` isolation** — only fires for matching id.
9. **`byAgent`** — multi-agent roster filters correctly.
10. **Retention eviction** — set `maxRetention: 5`, add 5 completed +
    1 more → oldest completed evicted, no active task affected.
11. **No drift on rapid updates** — 100 sequential `update()` calls
    produce 100 subscriber fires (no batching).
12. **Subscriber leak** — unsubscribe stops all future fires.

`headless-preact/src/use-task-queue.test.tsx`:

13. **Hook reactivity** — Preact re-renders on update.
14. **`useTask` undefined** — `undefined` for unknown id, no throw.

`jest-axe` against task-rail fixture with 5 tasks across all states.

## 9. Migration path

Consumer migrations (separate PRs):

1. **Goal verifier rail** — replaces inline JSON cache.
2. **Keeper card current-task badge** — `useTasksForAgent(agentId)`,
   filter `state === "running"`.
3. **Activity feed** — `useTaskQueue(manager).byState("completed")`
   plus failed; renders inside `role="log"` with `aria-live="polite"`
   container, fed from `announceStateChange()`.

Backend SSE bridge calls `add` / `update` — all surfaces re-render.

## 10. Merge criteria

- [ ] `headless-core/src/task-queue.ts` lands
- [ ] All 12 core + 2 hook tests pass under `vitest --run`
- [ ] `jest-axe` passes on task-rail fixture
- [ ] `headless-preact/src/use-task-queue.ts` lands
- [ ] One consumer migrates as proof-of-pattern (Goal verifier rail
      recommended — heaviest current logic)
- [ ] CHANGELOG entry under v0.5
- [ ] RFC 0008 implementation merged first (`agentId` cross-ref)

## 11. Open questions

1. **Pause / resume policy** — does `paused` decrement priority for
   `byPriority()` ordering, so paused tasks sink? Current proposal:
   no, paused stays where running was. Confirm.
2. **`reorder` persistence** — should the override survive page
   reload? Current proposal: no (memory only). Confirm whether
   localStorage persistence is wanted.
3. **`failed` retry transition** — when a failed task retries, is it
   the same id (state flips back to `queued`) or a new task? Current
   proposal: same id, audit log records the prior failure. Confirm.

These do not block draft acceptance but must close before the
implementation PR opens.
