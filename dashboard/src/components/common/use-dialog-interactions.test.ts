// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useDialogInteractions } from './use-dialog-interactions'

function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function tickEffect() {
  return new Promise((r) => setTimeout(r, 10))
}

function DialogTester({ open, onClose }: { open: boolean; onClose?: () => void }) {
  const { ref, dialogProps } = useDialogInteractions({ open, onClose })
  return html`
    <div ref=${ref} ...${dialogProps} data-testid="dialog">
      <button>first</button>
      <button>last</button>
    </div>
  `
}

describe('useDialogInteractions', () => {
  let container: HTMLElement
  let originalBodyPosition: string
  let originalBodyTop: string

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    originalBodyPosition = document.body.style.position
    originalBodyTop = document.body.style.top
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    document.body.style.position = originalBodyPosition
    document.body.style.top = originalBodyTop
    document.body.style.left = ''
    document.body.style.right = ''
  })

  it('sets dialog attributes when open', async () => {
    render(html`<${DialogTester} open=${true} />`, container)
    await tick()
    const el = container.querySelector('[data-testid="dialog"]') as HTMLElement
    expect(el).not.toBeNull()
    expect(el.getAttribute('role')).toBe('dialog')
    expect(el.getAttribute('aria-modal')).toBe('true')
    expect(el.getAttribute('data-state')).toBe('open')
  })

  it('sets data-state to closed when not open', async () => {
    render(html`<${DialogTester} open=${false} />`, container)
    await tick()
    const el = container.querySelector('[data-testid="dialog"]') as HTMLElement
    expect(el.getAttribute('data-state')).toBe('closed')
  })

  it('locks body scroll when open', async () => {
    render(html`<${DialogTester} open=${true} />`, container)
    await tickEffect()
    expect(document.body.style.position).toBe('fixed')
  })

  it('restores body scroll on unmount', async () => {
    render(html`<${DialogTester} open=${true} />`, container)
    await tickEffect()
    render(null, container)
    await tickEffect()
    expect(document.body.style.position).toBe('')
  })

  it('calls onClose on Escape key', async () => {
    const onClose = vi.fn()
    render(html`<${DialogTester} open=${true} onClose=${onClose} />`, container)
    await tickEffect()
    const el = container.querySelector('[data-testid="dialog"]') as HTMLElement
    const ev = new Event('keydown', { bubbles: true }) as any
    ev.key = 'Escape'
    el.dispatchEvent(ev)
    await tick()
    expect(onClose).toHaveBeenCalledOnce()
  })
})
