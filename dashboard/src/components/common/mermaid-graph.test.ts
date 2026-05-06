import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { MermaidGraph } from './mermaid-graph'

const mockRender = vi.fn()
const mockInitialize = vi.fn()
const containers: HTMLDivElement[] = []

function createContainer(): HTMLDivElement {
  const container = document.createElement('div')
  containers.push(container)
  return container
}

vi.mock('mermaid', () => ({
  default: {
    initialize: mockInitialize,
    render: mockRender,
  },
}))

describe('MermaidGraph', () => {
  beforeEach(() => {
    mockRender.mockReset()
    mockInitialize.mockReset()
    mockRender.mockResolvedValue({ svg: '<svg><rect /></svg>' })
  })

  afterEach(() => {
    for (const container of containers) {
      render(null, container)
    }
    containers.length = 0
    vi.clearAllMocks()
  })

  it('applies class and minHeightClass', async () => {
    const container = createContainer()
    render(
      h(MermaidGraph, {
        source: 'graph TD; A-->B',
        class: 'my-class',
        minHeightClass: 'min-h-20',
      }),
      container,
    )
    const outer = container.firstElementChild as HTMLElement
    expect(outer?.classList.contains('my-class')).toBe(true)
    expect(outer?.classList.contains('min-h-20')).toBe(true)
    await waitFor(() => {
      expect(container.querySelector('svg')).not.toBeNull()
    })
  })

  it('calls mermaid render on mount', async () => {
    const container = createContainer()
    render(h(MermaidGraph, { source: 'graph TD; A-->B' }), container)
    await waitFor(() => {
      expect(mockRender).toHaveBeenCalled()
    })
    const [, source] = mockRender.mock.calls[0] as [string, string]
    expect(source).toBe('graph TD; A-->B')
  })

  it('shows error when render throws', async () => {
    mockRender.mockRejectedValueOnce(new Error('mermaid fail'))
    const container = createContainer()
    render(h(MermaidGraph, { source: 'bad' }), container)
    await waitFor(() => {
      expect(container.textContent).toContain('mermaid fail')
    })
  })

  it('shows fallbackText on error', async () => {
    mockRender.mockRejectedValueOnce(new Error('fail'))
    const container = createContainer()
    render(h(MermaidGraph, { source: 'bad', fallbackText: 'fallback info' }), container)
    await waitFor(() => {
      expect(container.textContent).toContain('fallback info')
    })
  })

  it('renders host with role and aria-label', async () => {
    const container = createContainer()
    render(h(MermaidGraph, { source: 'graph TD; A-->B', fallbackText: 'my diagram' }), container)
    const host = container.querySelector('[role="img"]') as HTMLElement
    expect(host).not.toBeNull()
    expect(host?.getAttribute('aria-label')).toBe('my diagram')
    await waitFor(() => {
      expect(container.querySelector('svg')).not.toBeNull()
    })
  })

  it('applies diagramClass to host', async () => {
    const container = createContainer()
    render(
      h(MermaidGraph, { source: 'graph TD; A-->B', diagramClass: 'diag-special' }),
      container,
    )
    const host = container.querySelector('[role="img"]') as HTMLElement
    expect(host?.classList.contains('diag-special')).toBe(true)
    await waitFor(() => {
      expect(container.querySelector('svg')).not.toBeNull()
    })
  })

  it('shows SVG parse error as fallback', async () => {
    mockRender.mockResolvedValueOnce({ svg: '<not-svg>bad</not-svg>' })
    const container = createContainer()
    render(h(MermaidGraph, { source: 'x' }), container)
    await waitFor(() => {
      expect(container.textContent).toContain('SVG parse failed')
    })
  })
})
