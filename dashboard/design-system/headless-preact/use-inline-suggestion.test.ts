// @vitest-environment happy-dom
//
// Tests for headless-preact/use-inline-suggestion. Verifies hook
// reactivity over the headless InlineSuggestionManager and that
// useSuggestionController returns sane root/button props.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  createInlineSuggestionManager,
  type InlineSuggestionInput,
} from '../headless-core/inline-suggestion'
import {
  useFileSuggestions,
  useSuggestionController,
  useTopSuggestion,
} from './use-inline-suggestion'

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

function makeInput(overrides: Partial<InlineSuggestionInput> = {}): InlineSuggestionInput {
  return {
    agentId: 'a',
    agentName: 'Alice',
    agentColorSlot: 1,
    range: { file: 'src/foo.ts', fromLine: 10, toLine: 12 },
    before: ['  return null'],
    after: ['  return undefined'],
    confidence: 0.9,
    ...overrides,
  }
}

describe('useFileSuggestions', () => {
  it('returns empty for unknown file', async () => {
    const manager = createInlineSuggestionManager({ ttlMs: 0 })
    let captured: ReadonlyArray<unknown> = []
    function Probe(): unknown {
      captured = useFileSuggestions(manager, 'src/missing.ts')
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured).toEqual([])
  })

  it('reflects propose / retract for the watched file', async () => {
    const manager = createInlineSuggestionManager({ ttlMs: 0 })
    let captured: ReadonlyArray<{ id: string }> = []
    function Probe(): unknown {
      captured = useFileSuggestions(manager, 'src/foo.ts')
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    const id = manager.propose(makeInput())
    await flushEffects()
    expect(captured.map((s) => s.id)).toEqual([id])
    manager.retract(id)
    await flushEffects()
    expect(captured).toEqual([])
  })

  it('does not re-render on changes in unrelated file', async () => {
    const manager = createInlineSuggestionManager({ ttlMs: 0 })
    let renders = 0
    function Probe(): unknown {
      renders += 1
      useFileSuggestions(manager, 'src/foo.ts')
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    const before = renders
    manager.propose(
      makeInput({ range: { file: 'src/other.ts', fromLine: 1, toLine: 2 } }),
    )
    await flushEffects()
    expect(renders).toBe(before)
  })
})

describe('useTopSuggestion', () => {
  it('returns highest confidence containing line', async () => {
    const manager = createInlineSuggestionManager({ ttlMs: 0 })
    manager.propose(makeInput({ confidence: 0.4 }))
    manager.propose(makeInput({ confidence: 0.95 }))
    let captured: { confidence: number } | undefined
    function Probe(): unknown {
      captured = useTopSuggestion(manager, 'src/foo.ts', 11)
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured?.confidence).toBe(0.95)
  })

  it('returns undefined when no suggestion contains line', async () => {
    const manager = createInlineSuggestionManager({ ttlMs: 0 })
    manager.propose(makeInput())
    let captured: unknown
    function Probe(): unknown {
      captured = useTopSuggestion(manager, 'src/foo.ts', 99)
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured).toBeUndefined()
  })
})

describe('useSuggestionController', () => {
  it('returns controller with root + button props', async () => {
    const manager = createInlineSuggestionManager({ ttlMs: 0 })
    const id = manager.propose(makeInput())
    let captured: ReturnType<typeof useSuggestionController>
    function Probe(): unknown {
      captured = useSuggestionController(manager, id)
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured).toBeDefined()
    const root = captured!.getRootProps()
    expect(root.role).toBe('region')
    expect(root['aria-keyshortcuts']).toBe('Tab Escape')
    expect(root.tabIndex).toBe(0)
    expect(captured!.getAcceptButtonProps().type).toBe('button')
    expect(captured!.getRejectButtonProps().type).toBe('button')
  })

  it('returns undefined for missing id (no throw)', async () => {
    const manager = createInlineSuggestionManager({ ttlMs: 0 })
    let captured: unknown = 'placeholder'
    function Probe(): unknown {
      captured = useSuggestionController(manager, 'inline-suggestion-missing')
      return null
    }
    render(html`<${Probe} />`, container)
    await flushEffects()
    expect(captured).toBeUndefined()
  })
})
