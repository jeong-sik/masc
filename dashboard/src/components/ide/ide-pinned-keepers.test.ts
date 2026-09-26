import { afterEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { IdePinnedKeepers } from './ide-pinned-keepers'
import { clearPins, pinKeeper, pinnedKeepers } from './multi-keeper-pin-store'

describe('IdePinnedKeepers', () => {
  const container = document.createElement('div')

  afterEach(() => {
    render(null, container)
    clearPins()
  })

  it('renders nothing until a keeper is pinned', () => {
    render(h(IdePinnedKeepers, { onOpenKeeper: () => {} }), container)
    expect(container.querySelector('[data-testid="ide-pinned-keepers"]')).toBeNull()
  })

  // Pins were state with no view: the gutter pinned, Mod+Shift+1..4
  // reordered, and nothing on screen changed.
  it('shows pins head first, opens one as the IDE keeper and unpins with ×', async () => {
    const opened = vi.fn()
    pinKeeper('alpha', 3)
    pinKeeper('beta', null)
    render(h(IdePinnedKeepers, { onOpenKeeper: opened }), container)

    const labels = () => [...container.querySelectorAll('[data-testid="ide-pinned-keeper"] > span:last-child')]
      .map(label => label.textContent?.trim())
    expect(labels()).toEqual(['beta', 'alpha · L3'])
    expect(container.querySelector('[data-testid="ide-pinned-keeper"]')?.getAttribute('aria-current')).toBe('true')

    fireEvent.click(container.querySelectorAll('[data-testid="ide-pinned-keeper"]')[1]!)
    expect(opened).toHaveBeenCalledWith('alpha')
    await waitFor(() => expect(labels()).toEqual(['alpha · L3', 'beta']))

    fireEvent.click(container.querySelector('[aria-label="Unpin alpha"]')!)
    await waitFor(() => expect(labels()).toEqual(['beta']))
    expect(pinnedKeepers.value.entries.map(entry => entry.keeperName)).toEqual(['beta'])
  })
})
