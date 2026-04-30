/** @jsxImportSource solid-js */

/**
 * solid-poc — Visual proof that SolidJS coexists with Preact in the
 * same Vite app and that the framework-agnostic TaskQueueManager
 * primitive (RFC 0009) drives Solid's reactive graph correctly.
 *
 * Hidden — not linked from index.html. Loaded only when navigating
 * directly to /design-system/preview/solid-poc.html.
 *
 * RFC 0017 PR #1 verification step 5.
 */

import { createSignal, For, type Component } from 'solid-js'
import { render } from 'solid-js/web'
import { createTaskQueueManager } from '../headless-core/task-queue'
import { useTaskQueue } from '../headless-solid/use-task-queue'

const manager = createTaskQueueManager({
  initialTasks: [
    { id: 'seed-1', agentId: 'alice', title: 'Run benchmark suite', priority: 5, state: 'running' },
    { id: 'seed-2', agentId: 'bob', title: 'Review PR #12110', priority: 3, state: 'queued' },
    { id: 'seed-3', agentId: 'alice', title: 'Update RFC 0017', priority: 2, state: 'queued' },
  ],
})

const App: Component = () => {
  const { tasks, byState } = useTaskQueue(manager)
  const [nextId, setNextId] = createSignal(4)

  const addTask = (): void => {
    const n = nextId()
    setNextId(n + 1)
    manager.add({
      id: `live-${n}`,
      agentId: ['alice', 'bob', 'carol'][n % 3]!,
      title: `Task #${n}`,
      priority: Math.floor(Math.random() * 5) + 1,
      state: 'queued',
    })
  }

  const completeFirst = (): void => {
    const queued = byState('queued')
    if (queued[0] !== undefined) {
      manager.update(queued[0].id, { state: 'completed' })
    }
  }

  return (
    <main class="solid-poc">
      <header>
        <h1>SolidJS PoC — useTaskQueue adapter</h1>
        <p class="muted">
          RFC 0017 verification: same TaskQueueManager (RFC 0009 primitive)
          driving a Solid reactive graph. Bundle chunked to <code>solid-*.js</code>.
        </p>
      </header>

      <section class="controls">
        <button type="button" onClick={addTask}>Add task</button>
        <button type="button" onClick={completeFirst}>Complete first queued</button>
      </section>

      <section>
        <h2>Tasks ({tasks().length})</h2>
        <ul class="task-list">
          <For each={tasks()}>
            {(t) => (
              <li class={`task task--${t.state}`}>
                <span class="task__id">{t.id}</span>
                <span class="task__title">{t.title}</span>
                <span class="task__agent">{t.agentId}</span>
                <span class="task__priority">P{t.priority}</span>
                <span class="task__state">{t.state}</span>
              </li>
            )}
          </For>
        </ul>
      </section>

      <footer>
        <code>queued: {byState('queued').length}</code>
        <code>running: {byState('running').length}</code>
        <code>completed: {byState('completed').length}</code>
      </footer>
    </main>
  )
}

const root = document.getElementById('app')
if (root === null) {
  throw new Error('solid-poc: #app not found')
}
render(() => <App />, root)
