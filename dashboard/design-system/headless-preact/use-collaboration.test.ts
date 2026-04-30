// @vitest-environment happy-dom
//
// Tests for headless-preact/use-collaboration. Verifies file-scoped
// reactivity over the headless CollaborationManager.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { createAgentPresenceManager } from '../headless-core/agent-presence'
import { createCollaborationManager } from '../headless-core/collaboration'
import { useFileConflicts, useFileCursors } from './use-collaboration'

function flushEffects(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 16))
}

let container: HTMLElement

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
})

afterEach(() => {
  render(null, container)
  container.remove()
})

function setupTwo(): {
  presence: ReturnType<typeof createAgentPresenceManager>
  collab: ReturnType<typeof createCollaborationManager>
} {
  const presence = createAgentPresenceManager({
    initialAgents: [
      {
        id: 'a',
        name: 'Alice',
        sigil: { text: 'A' },
        colorSlot: 1,
      },
      {
        id: 'b',
        name: 'Bob',
        sigil: { text: 'B' },
        colorSlot: 2,
      },
    ],
  })
  const collab = createCollaborationManager({ presence })
  return { presence, collab }
}

describe('useFileCursors', () => {
  it('initial snapshot has cursors that already exist', async () => {
    const { presence, collab } = setupTwo()
    presence.updateCursor('a', 'src/foo.ts', 10, 1)
    let captured: ReadonlyArray<{ file: string }> = []
    function Probe(): unknown {
      captured = useFileCursors(collab, 'src/foo.ts')
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.length).toBe(1)
    expect(captured[0]!.file).toBe('src/foo.ts')
  })

  it('re-renders on cursor add in subscribed file', async () => {
    const { presence, collab } = setupTwo()
    let captured: ReadonlyArray<unknown> = []
    function Probe(): unknown {
      captured = useFileCursors(collab, 'src/foo.ts')
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.length).toBe(0)
    presence.updateCursor('a', 'src/foo.ts', 5, 1)
    await flushEffects()
    expect(captured.length).toBe(1)
  })

  it('does not re-render on changes in unrelated file', async () => {
    const { presence, collab } = setupTwo()
    let renders = 0
    function Probe(): unknown {
      renders += 1
      useFileCursors(collab, 'src/foo.ts')
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    const before = renders
    presence.updateCursor('a', 'src/bar.ts', 5, 1)
    await flushEffects()
    expect(renders).toBe(before)
  })
})

describe('useFileConflicts', () => {
  it('returns conflicts only for subscribed file', async () => {
    const { presence, collab } = setupTwo()
    let captured: ReadonlyArray<{ file: string }> = []
    function Probe(): unknown {
      captured = useFileConflicts(collab, 'src/foo.ts')
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured.length).toBe(0)
    presence.updateCursor('a', 'src/foo.ts', 10, 1)
    presence.updateCursor('b', 'src/foo.ts', 10, 5)
    await flushEffects()
    expect(captured.length).toBe(1)
    expect(captured[0]!.file).toBe('src/foo.ts')
  })

  it('ignores conflicts in other files', async () => {
    const { presence, collab } = setupTwo()
    let captured: ReadonlyArray<unknown> = []
    function Probe(): unknown {
      captured = useFileConflicts(collab, 'src/foo.ts')
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    presence.updateCursor('a', 'src/other.ts', 10, 1)
    presence.updateCursor('b', 'src/other.ts', 10, 5)
    await flushEffects()
    expect(captured.length).toBe(0)
  })
})
