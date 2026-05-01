import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { CollaborationCanvas } from './collaboration-canvas'

const participants = [
  { id: 'p1', type: 'human' as const, name: 'Alice', color: '#ff0000' },
  { id: 'p2', type: 'agent' as const, name: 'Beta', color: '#00ff00', cursor: { x: 10, y: 20 } },
]

describe('CollaborationCanvas', () => {
  it('renders region role', () => {
    const container = document.createElement('div')
    render(h(CollaborationCanvas, { content: '', participants: [], onChange: vi.fn() }), container)
    expect(container.querySelector('[role="region"]')).not.toBeNull()
  })

  it('renders label', () => {
    const container = document.createElement('div')
    render(h(CollaborationCanvas, { content: '', participants: [], onChange: vi.fn() }), container)
    expect(container.textContent).toContain('협업 편집기')
  })

  it('renders participant badges', () => {
    const container = document.createElement('div')
    render(h(CollaborationCanvas, { content: '', participants, onChange: vi.fn() }), container)
    expect(container.textContent).toContain('Alice')
    expect(container.textContent).toContain('Beta')
  })

  it('renders participant list role', () => {
    const container = document.createElement('div')
    render(h(CollaborationCanvas, { content: '', participants, onChange: vi.fn() }), container)
    expect(container.querySelector('[aria-label="참여자 목록"]')).not.toBeNull()
  })

  it('renders listitem for each participant', () => {
    const container = document.createElement('div')
    render(h(CollaborationCanvas, { content: '', participants, onChange: vi.fn() }), container)
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(2)
  })

  it('renders textarea', () => {
    const container = document.createElement('div')
    render(h(CollaborationCanvas, { content: 'hello', participants: [], onChange: vi.fn() }), container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    expect(ta).not.toBeNull()
    expect(ta?.value).toBe('hello')
  })

  it('calls onChange on input', () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(CollaborationCanvas, { content: '', participants: [], onChange }), container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    ta.value = 'new text'
    ta.dispatchEvent(new Event('input'))
    expect(onChange).toHaveBeenCalledWith('new text')
  })

  it('renders cursor overlay for active participants', () => {
    const container = document.createElement('div')
    render(h(CollaborationCanvas, { content: '', participants, onChange: vi.fn() }), container)
    const cursors = container.querySelectorAll('[role="img"][aria-label*="커서"]')
    expect(cursors.length).toBe(1)
  })

  it('renders presence description', () => {
    const container = document.createElement('div')
    render(h(CollaborationCanvas, { content: '', participants, onChange: vi.fn() }), container)
    expect(container.textContent).toContain('편집 중입니다')
  })

  it('does not render presence when no active participants', () => {
    const container = document.createElement('div')
    const inactive = [{ id: 'p1', type: 'human' as const, name: 'Alice', color: '#ff0000' }]
    render(h(CollaborationCanvas, { content: '', participants: inactive, onChange: vi.fn() }), container)
    expect(container.textContent).not.toContain('편집 중입니다')
  })

  it('renders selection highlights', () => {
    const container = document.createElement('div')
    const withSel = [
      { id: 'p1', type: 'human' as const, name: 'Alice', color: '#ff0000', selection: { start: 0, end: 5 } },
    ]
    render(h(CollaborationCanvas, { content: 'hello', participants: withSel, onChange: vi.fn() }), container)
    expect(container.textContent).toContain('Alice 0-5')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(CollaborationCanvas, { content: '', participants: [], onChange: vi.fn(), testId: 'cc-1' }), container)
    expect(container.querySelector('[data-testid="cc-1"]')).not.toBeNull()
  })

  it('links textarea aria-labelledby to label', () => {
    const container = document.createElement('div')
    render(h(CollaborationCanvas, { content: '', participants: [], onChange: vi.fn(), testId: 'cc-1' }), container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    expect(ta?.getAttribute('aria-labelledby')).toBe('cc-1-label')
  })
})
