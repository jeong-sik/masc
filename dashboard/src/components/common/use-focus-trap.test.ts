import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { useFocusTrap } from './use-focus-trap'

function TrapContainer({ active, onClose }: { active: boolean; onClose?: () => void }) {
  const { ref, focusTrapProps } = useFocusTrap({ active, onClose })
  return h(
    'div',
    { ref, ...focusTrapProps, 'data-testid': 'trap' },
    h('button', {}, 'first'),
    h('button', {}, 'second'),
  )
}

describe('useFocusTrap', () => {
  it('returns tabIndex -1', () => {
    const container = document.createElement('div')
    render(h(TrapContainer, { active: true }), container)
    const el = container.querySelector('[data-testid="trap"]') as HTMLElement
    expect(el?.tabIndex).toBe(-1)
  })

  it('sets data-focus-trap when active', () => {
    const container = document.createElement('div')
    render(h(TrapContainer, { active: true }), container)
    const el = container.querySelector('[data-focus-trap]')
    expect(el?.getAttribute('data-focus-trap')).toBe('true')
  })

  it('does not set data-focus-trap when inactive', () => {
    const container = document.createElement('div')
    render(h(TrapContainer, { active: false }), container)
    const el = container.querySelector('[data-testid="trap"]')
    expect(el?.hasAttribute('data-focus-trap')).toBe(false)
  })

  it('calls onClose on Escape', async () => {
    const onClose = vi.fn()
    const container = document.createElement('div')
    render(h(TrapContainer, { active: true, onClose }), container)
    await new Promise((r) => setTimeout(r, 10))
    const ev = new Event('keydown', { bubbles: true })
    ;(ev as any).key = 'Escape'
    const trap = container.querySelector('[data-testid="trap"]') as HTMLElement
    trap.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    expect(onClose).toHaveBeenCalledOnce()
  })
})
