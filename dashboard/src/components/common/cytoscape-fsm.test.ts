// @ts-nocheck
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { CytoscapeFsm } from './cytoscape-fsm'

const mockCyInstance = {
  destroy: vi.fn(),
  elements: vi.fn(() => ({ remove: vi.fn() })),
  add: vi.fn(),
  batch: vi.fn((fn: () => void) => fn()),
  layout: vi.fn(() => ({ run: vi.fn() })),
  on: vi.fn(),
  fit: vi.fn(),
}

vi.mock('cytoscape', () => ({
  default: vi.fn(() => mockCyInstance),
}))

describe('CytoscapeFsm', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockCyInstance.destroy.mockClear()
    mockCyInstance.elements.mockClear()
    mockCyInstance.add.mockClear()
    mockCyInstance.batch.mockClear()
    mockCyInstance.layout.mockClear()
    mockCyInstance.on.mockClear()
    mockCyInstance.fit.mockClear()
  })

  const baseSpec = {
    nodes: [{ id: 's1', label: 'State 1', type: 'state' as const }],
    edges: [],
  }

  it('renders container with class', () => {
    const container = document.createElement('div')
    render(h(CytoscapeFsm, { spec: baseSpec, class: 'my-graph' }), container)
    expect(container.querySelector('.my-graph')).not.toBeNull()
  })

  it('shows loading spinner initially', () => {
    const container = document.createElement('div')
    render(h(CytoscapeFsm, { spec: baseSpec }), container)
    expect(container.textContent).toContain('그래프 로딩중')
  })

  it('calls cytoscape after mount', async () => {
    const container = document.createElement('div')
    render(h(CytoscapeFsm, { spec: baseSpec }), container)
    await new Promise((r) => setTimeout(r, 10))
    const cytoscape = (await import('cytoscape')).default
    expect(cytoscape).toHaveBeenCalled()
  })

  it('passes height to inner container', () => {
    const container = document.createElement('div')
    render(h(CytoscapeFsm, { spec: baseSpec, height: '400px' }), container)
    const inner = container.querySelector('div[style]') as HTMLElement
    expect(inner?.style.height).toBe('400px')
  })

  it('hides loading after init', async () => {
    const container = document.createElement('div')
    render(h(CytoscapeFsm, { spec: baseSpec }), container)
    await new Promise((r) => setTimeout(r, 10))
    expect(container.textContent).not.toContain('그래프 로딩중')
  })

  it('shows error when cytoscape throws', async () => {
    const cytoscape = (await import('cytoscape')).default
    cytoscape.mockImplementationOnce(() => {
      throw new Error('fail')
    })
    const container = document.createElement('div')
    render(h(CytoscapeFsm, { spec: baseSpec }), container)
    await new Promise((r) => setTimeout(r, 10))
    expect(container.textContent).toContain('fail')
  })

  it('updates elements when spec changes', async () => {
    const container = document.createElement('div')
    render(h(CytoscapeFsm, { spec: baseSpec }), container)
    await new Promise((r) => setTimeout(r, 10))

    mockCyInstance.elements.mockClear()
    mockCyInstance.add.mockClear()
    mockCyInstance.layout.mockClear()

    render(
      h(CytoscapeFsm, {
        spec: {
          nodes: [
            { id: 's1', label: 'State 1', type: 'state' as const },
            { id: 's2', label: 'State 2', type: 'active' as const },
          ],
          edges: [{ source: 's1', target: 's2' }],
        },
      }),
      container,
    )
    await new Promise((r) => setTimeout(r, 10))
    expect(mockCyInstance.elements).toHaveBeenCalled()
  })
})
