import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

// Stub KeeperTurnInspector so the drawer can be tested without the inner
// component's self-fetch of turn records. Surfaces its anchor props as data
// attributes for assertion.
vi.mock('./keeper-turn-inspector', () => ({
  KeeperTurnInspector: ({ keeperName, initialTurnRef, initialTurnTimestamp }: any) =>
    h('div', {
      'data-testid': 'turn-inspector-inner',
      'data-keeper': keeperName,
      'data-initial-turn-ref': initialTurnRef ?? '',
      'data-initial-turn-timestamp': initialTurnTimestamp ?? '',
    }),
}))

import { TurnInspectorDrawer } from './keeper-turn-inspector-drawer'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('TurnInspectorDrawer', () => {
  it('renders nothing when closed', () => {
    const { container } = render(
      h(TurnInspectorDrawer, { keeperName: 'echo', open: false, onClose: () => {}, testId: 'x' }),
    )
    expect(container.querySelector('[data-testid="x-drawer"]')).toBeNull()
  })

  it('renders the drawer and threads anchor props to the inspector when open', () => {
    render(
      h(TurnInspectorDrawer, {
        keeperName: 'echo',
        subtitle: '원본 턴 · trace-a#9',
        initialTurnRef: 'trace-a#9',
        open: true,
        onClose: () => {},
        testId: 'board-post-turn-inspector',
      }),
    )
    expect(screen.getByTestId('board-post-turn-inspector-drawer')).toBeInTheDocument()
    expect(screen.getByText('원본 턴 · trace-a#9')).toBeInTheDocument()
    const inner = screen.getByTestId('turn-inspector-inner')
    expect(inner.getAttribute('data-keeper')).toBe('echo')
    expect(inner.getAttribute('data-initial-turn-ref')).toBe('trace-a#9')
  })

  it('falls back to keeperName in the header when no subtitle is given', () => {
    render(h(TurnInspectorDrawer, { keeperName: 'echo', open: true, onClose: () => {}, testId: 'x' }))
    // The header secondary line shows the keeper name when subtitle is absent.
    expect(screen.getByText('echo')).toBeInTheDocument()
  })

  it('invokes onClose from the close button (testId-namespaced)', () => {
    const onClose = vi.fn()
    render(h(TurnInspectorDrawer, { keeperName: 'echo', open: true, onClose, testId: 'x' }))
    fireEvent.click(screen.getByTestId('x-close'))
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})
