// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { act, fireEvent } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { PopoverMenu, QuickPeekDrawer } from './index'

describe('PopoverMenu primitive', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('opens on click, navigates items with ArrowDown/ArrowUp/Home/End, selects an item, and restores focus on Escape', async () => {
    const onSelectA = vi.fn()
    const onSelectB = vi.fn()
    const onSelectC = vi.fn()

    await act(async () => {
      render(
        html`
          <div>
            <${PopoverMenu}
              triggerLabel="Actions"
              triggerTestId="pm-trigger"
              popoverTestId="pm-menu"
              align="right"
              ariaLabel="작업 메뉴"
              items=${[
                { id: 'a', label: 'Alpha', testId: 'pm-a', onSelect: onSelectA },
                { id: 'disabled', label: 'Disabled', disabled: true, testId: 'pm-disabled', onSelect: vi.fn() },
                { id: 'b', label: 'Beta', separatorBefore: true, testId: 'pm-b', onSelect: onSelectB },
                { id: 'c', label: 'Gamma', danger: true, testId: 'pm-c', onSelect: onSelectC },
              ]}
            />
            <button type="button" data-testid="outside-btn">Outside</button>
          </div>
        `,
        container,
      )
    })

    const trigger = container.querySelector('[data-testid="pm-trigger"]') as HTMLButtonElement
    expect(trigger.getAttribute('aria-expanded')).toBe('false')
    expect(container.querySelector('[data-testid="pm-menu"]')).toBeNull()

    // ArrowDown on closed trigger opens menu and focuses first enabled item
    trigger.focus()
    await act(async () => {
      fireEvent.keyDown(trigger, { key: 'ArrowDown' })
      await Promise.resolve()
    })

    const menu = container.querySelector('[data-testid="pm-menu"]') as HTMLElement
    expect(menu).not.toBeNull()
    expect(menu.getAttribute('data-align')).toBe('right')
    expect(menu.querySelector('[role="separator"]')).not.toBeNull()
    expect(trigger.getAttribute('aria-expanded')).toBe('true')

    const itemA = container.querySelector('[data-testid="pm-a"]') as HTMLButtonElement
    const itemB = container.querySelector('[data-testid="pm-b"]') as HTMLButtonElement
    const itemC = container.querySelector('[data-testid="pm-c"]') as HTMLButtonElement
    expect(document.activeElement).toBe(itemA)

    // ArrowDown skips disabled item and lands on Beta
    await act(async () => {
      fireEvent.keyDown(menu, { key: 'ArrowDown' })
    })
    expect(document.activeElement).toBe(itemB)

    // End jumps to Gamma, Home jumps back to Alpha, ArrowUp wraps to Gamma
    await act(async () => {
      fireEvent.keyDown(menu, { key: 'End' })
    })
    expect(document.activeElement).toBe(itemC)

    await act(async () => {
      fireEvent.keyDown(menu, { key: 'Home' })
    })
    expect(document.activeElement).toBe(itemA)

    await act(async () => {
      fireEvent.keyDown(menu, { key: 'ArrowUp' })
    })
    expect(document.activeElement).toBe(itemC)

    // Escape closes menu and restores focus to trigger
    await act(async () => {
      fireEvent.keyDown(menu, { key: 'Escape' })
    })
    expect(container.querySelector('[data-testid="pm-menu"]')).toBeNull()
    expect(document.activeElement).toBe(trigger)

    // Click trigger -> select item B -> closes menu & invokes onSelectB
    await act(async () => {
      fireEvent.click(trigger)
    })
    await act(async () => {
      fireEvent.click(container.querySelector('[data-testid="pm-b"]') as HTMLButtonElement)
    })
    expect(onSelectB).toHaveBeenCalledTimes(1)
    expect(container.querySelector('[data-testid="pm-menu"]')).toBeNull()

    // Outside mousedown dismisses popover
    await act(async () => {
      fireEvent.click(trigger)
    })
    expect(container.querySelector('[data-testid="pm-menu"]')).not.toBeNull()
    const outsideBtn = container.querySelector('[data-testid="outside-btn"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.mouseDown(outsideBtn)
    })
    expect(container.querySelector('[data-testid="pm-menu"]')).toBeNull()
  })

  it('supports controlled open state and custom children render function', async () => {
    const onOpenChange = vi.fn()
    const renderControlled = (open: boolean) => html`
      <${PopoverMenu}
        open=${open}
        onOpenChange=${onOpenChange}
        triggerLabel="Filter"
        triggerTestId="ctrl-trigger"
        popoverTestId="ctrl-menu"
        ariaLabel="필터 메뉴"
      >
        ${({ close }: { readonly close: () => void }) => html`
          <button type="button" role="menuitem" class="pm-item" data-testid="custom-close" onClick=${close}>
            Done
          </button>
        `}
      <//>
    `

    await act(async () => {
      render(renderControlled(false), container)
    })
    expect(container.querySelector('[data-testid="ctrl-menu"]')).toBeNull()

    await act(async () => {
      fireEvent.click(container.querySelector('[data-testid="ctrl-trigger"]') as HTMLButtonElement)
    })
    expect(onOpenChange).toHaveBeenCalledWith(true)

    await act(async () => {
      render(renderControlled(true), container)
    })
    expect(container.querySelector('[data-testid="ctrl-menu"]')).not.toBeNull()

    await act(async () => {
      fireEvent.click(container.querySelector('[data-testid="custom-close"]') as HTMLButtonElement)
    })
    expect(onOpenChange).toHaveBeenLastCalledWith(false)
  })

  it('renders menuitemradio with aria-checked for selectable items and keeps plain action items as menuitem', async () => {
    await act(async () => {
      render(
        html`
          <${PopoverMenu}
            defaultOpen=${true}
            triggerLabel="Window"
            triggerTestId="radio-trigger"
            popoverTestId="radio-menu"
            ariaLabel="시간 창 메뉴"
            items=${[
              { id: '24h', label: '24h', active: true, testId: 'opt-24h', onSelect: vi.fn() },
              { id: '7d', label: '7d', active: false, testId: 'opt-7d', onSelect: vi.fn() },
              { id: 'reset', label: 'Reset', separatorBefore: true, testId: 'opt-reset', onSelect: vi.fn() },
            ]}
          />
        `,
        container,
      )
    })

    const opt24h = container.querySelector('[data-testid="opt-24h"]') as HTMLButtonElement
    const opt7d = container.querySelector('[data-testid="opt-7d"]') as HTMLButtonElement
    const optReset = container.querySelector('[data-testid="opt-reset"]') as HTMLButtonElement

    expect(opt24h.getAttribute('role')).toBe('menuitemradio')
    expect(opt24h.getAttribute('aria-checked')).toBe('true')
    expect(opt24h.getAttribute('aria-current')).toBeNull()
    expect(opt24h.getAttribute('data-active')).toBe('true')

    expect(opt7d.getAttribute('role')).toBe('menuitemradio')
    expect(opt7d.getAttribute('aria-checked')).toBe('false')
    expect(opt7d.getAttribute('aria-current')).toBeNull()
    expect(opt7d.getAttribute('data-active')).toBeNull()

    expect(optReset.getAttribute('role')).toBe('menuitem')
    expect(optReset.getAttribute('aria-checked')).toBeNull()
    expect(optReset.getAttribute('aria-current')).toBeNull()

    // Keyboard navigation still traverses menuitemradio + menuitem entries
    const menu = container.querySelector('[data-testid="radio-menu"]') as HTMLElement
    opt24h.focus()
    await act(async () => {
      fireEvent.keyDown(menu, { key: 'ArrowDown' })
    })
    expect(document.activeElement).toBe(opt7d)
    await act(async () => {
      fireEvent.keyDown(menu, { key: 'ArrowDown' })
    })
    expect(document.activeElement).toBe(optReset)
  })

  it('stops Escape propagation before existing document listeners and underlying QuickPeekDrawer', async () => {
    const existingDocEscape = vi.fn()
    const laterCaptureEscape = vi.fn()
    const onDrawerClose = vi.fn()

    document.addEventListener('keydown', existingDocEscape)
    try {
      await act(async () => {
        render(
          html`
            <div>
              <${QuickPeekDrawer} open=${true} title="Inspector" onClose=${onDrawerClose}>
                <${PopoverMenu}
                  triggerLabel="Options"
                  triggerTestId="esc-trigger"
                  popoverTestId="esc-menu"
                  ariaLabel="옵션 메뉴"
                  items=${[
                    { id: 'one', label: 'One', active: true, testId: 'esc-one', onSelect: vi.fn() },
                  ]}
                />
              <//>
            </div>
          `,
          container,
        )
      })

      const trigger = container.querySelector('[data-testid="esc-trigger"]') as HTMLButtonElement
      await act(async () => {
        fireEvent.click(trigger)
      })
      expect(container.querySelector('[data-testid="esc-menu"]')).not.toBeNull()

      document.addEventListener('keydown', laterCaptureEscape, true)
      // Escape dispatched on trigger/body goes through PopoverMenu's document listener
      await act(async () => {
        fireEvent.keyDown(trigger, { key: 'Escape' })
      })

      expect(container.querySelector('[data-testid="esc-menu"]')).toBeNull()
      expect(document.activeElement).toBe(trigger)
      expect(existingDocEscape).not.toHaveBeenCalled()
      expect(laterCaptureEscape).not.toHaveBeenCalled()
      expect(onDrawerClose).not.toHaveBeenCalled()

      // Once PopoverMenu is closed, a subsequent Escape reaches existing listeners and closes the drawer
      await act(async () => {
        fireEvent.keyDown(document.body, { key: 'Escape' })
      })
      expect(existingDocEscape).toHaveBeenCalledTimes(1)
      expect(onDrawerClose).toHaveBeenCalledTimes(1)
    } finally {
      document.removeEventListener('keydown', existingDocEscape)
      document.removeEventListener('keydown', laterCaptureEscape, true)
    }
  })

  it('QuickPeekDrawer styles subtitle with .qpeek-sub', async () => {
    await act(async () => {
      render(
        html`
          <${QuickPeekDrawer} open=${true} title="Inspector" subtitle="Read-Only Snapshot" onClose=${() => {}}>
            <p>Body</p>
          <//>
        `,
        container,
      )
    })
    const sub = container.querySelector('.qpeek-sub')
    expect(sub).not.toBeNull()
    expect(sub?.textContent).toBe('Read-Only Snapshot')
  })
})
