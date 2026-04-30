import { describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { render } from '@testing-library/preact'
import { act } from 'preact/test-utils'
import { axe } from 'jest-axe'

import {
  CollaborationCanvas,
  CanvasParticipant,
} from './collaboration-canvas'

function renderInAct(ui: ReturnType<typeof html>) {
  let result: ReturnType<typeof render>
  act(() => {
    result = render(ui)
  })
  return result!
}

const mockParticipants: CanvasParticipant[] = [
  {
    id: 'p1',
    type: 'human',
    name: 'Alice',
    color: '#ff0000',
    cursor: { x: 10, y: 20 },
  },
  {
    id: 'p2',
    type: 'agent',
    name: 'Kimi',
    color: '#00ff00',
    selection: { start: 0, end: 5 },
  },
]

describe('CollaborationCanvas a11y', () => {
  it('has no axe violations', async () => {
    const { container } = renderInAct(
      html`<${CollaborationCanvas}
        content="hello world"
        participants=${mockParticipants}
        onChange=${vi.fn()}
      />`
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has region role and label', () => {
    const { container } = renderInAct(
      html`<${CollaborationCanvas}
        content="test"
        participants=${[]}
        onChange=${vi.fn()}
      />`
    )
    const region = container.querySelector('[role="region"]')
    expect(region).not.toBeNull()
    expect(region?.getAttribute('aria-label')).toBe('협업 편집 영역')
  })

  it('textarea is labelled by span', () => {
    const { container } = renderInAct(
      html`<${CollaborationCanvas}
        content="test"
        participants=${[]}
        onChange=${vi.fn()}
      />`
    )
    const textarea = container.querySelector('textarea')
    expect(textarea).not.toBeNull()
    const labelId = textarea?.getAttribute('aria-labelledby')
    expect(labelId).toBeTruthy()
    const label = document.getElementById(labelId!)
    expect(label?.textContent).toContain('협업 편집기')
  })

  it('participant list has list role', () => {
    const { container } = renderInAct(
      html`<${CollaborationCanvas}
        content="test"
        participants=${mockParticipants}
        onChange=${vi.fn()}
      />`
    )
    const list = container.querySelector('[role="list"]')
    expect(list).not.toBeNull()
    expect(list?.getAttribute('aria-label')).toBe('참여자 목록')
  })

  it('each participant is a listitem with accessible name', () => {
    const { container } = renderInAct(
      html`<${CollaborationCanvas}
        content="test"
        participants=${mockParticipants}
        onChange=${vi.fn()}
      />`
    )
    const items = container.querySelectorAll('[role="listitem"]')
    expect(items.length).toBe(2)
    expect(items[0].getAttribute('aria-label')).toBe('Alice (사람)')
    expect(items[1].getAttribute('aria-label')).toBe('Kimi (에이전트)')
  })

  it('cursor indicators have img role and labels', () => {
    const { container } = renderInAct(
      html`<${CollaborationCanvas}
        content="test"
        participants=${mockParticipants}
        onChange=${vi.fn()}
      />`
    )
    const cursors = container.querySelectorAll('[role="img"]')
    expect(cursors.length).toBeGreaterThanOrEqual(1)
    expect(cursors[0].getAttribute('aria-label')).toBe('Alice 커서')
  })

  it('presence description is present when participants are active', () => {
    const { container } = renderInAct(
      html`<${CollaborationCanvas}
        content="test"
        participants=${mockParticipants}
        onChange=${vi.fn()}
      />`
    )
    const desc = container.querySelector('#presence-desc')
    expect(desc).not.toBeNull()
    expect(desc?.textContent).toContain('편집 중입니다')
  })

  it('onChange fires on input', async () => {
    const onChange = vi.fn()
    const { container } = renderInAct(
      html`<${CollaborationCanvas}
        content="initial"
        participants=${[]}
        onChange=${onChange}
      />`
    )
    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    await act(async () => {
      textarea.value = 'changed'
      textarea.dispatchEvent(new Event('input'))
    })
    expect(onChange).toHaveBeenCalledWith('changed')
  })

  it('empty participants has no axe violations', async () => {
    const { container } = renderInAct(
      html`<${CollaborationCanvas}
        content=""
        participants=${[]}
        onChange=${vi.fn()}
      />`
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
