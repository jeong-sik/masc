// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { html } from 'htm/preact'
import { KeeperConfigPanel } from './keeper-config-panel-v2'

describe('KeeperConfigPanel v2', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders the drawer with keeper identity', () => {
    render(
      html`<${KeeperConfigPanel} keeper=${{ id: 'sangsu', ns: 'masc-mcp' }} />`,
      container,
    )

    expect(container.querySelector('[data-testid="keeper-config-panel"]')).not.toBeNull()
    expect(container.textContent).toContain('keeper 설정')
    expect(container.textContent).toContain('sangsu')
    expect(container.textContent).toContain('masc-mcp')
  })

  it('calls onClose when the close button is clicked', async () => {
    const onClose = vi.fn()
    render(
      html`<${KeeperConfigPanel} keeper=${{ id: 'sangsu' }} asOverlay onClose=${onClose} />`,
      container,
    )

    const closeButton = container.querySelector('[data-testid="kcp-close"]') as HTMLButtonElement | null
    expect(closeButton).not.toBeNull()
    await fireEvent.click(closeButton!)
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('updates persona textarea', () => {
    render(
      html`<${KeeperConfigPanel} keeper=${{ id: 'sangsu' }} base=${{ persona: 'helpful' }} />`,
      container,
    )

    const textarea = container.querySelector('[data-testid="kcp-persona"]') as HTMLTextAreaElement | null
    expect(textarea).not.toBeNull()
    expect(textarea!.value).toBe('helpful')

    textarea!.value = 'diligent'
    textarea!.dispatchEvent(new Event('input', { bubbles: true }))

    expect(textarea!.value).toBe('diligent')
  })

  it('updates instructions textarea', () => {
    render(
      html`<${KeeperConfigPanel} keeper=${{ id: 'sangsu' }} base=${{ instructions: 'do x' }} />`,
      container,
    )

    const textarea = container.querySelector('[data-testid="kcp-instructions"]') as HTMLTextAreaElement | null
    expect(textarea).not.toBeNull()
    expect(textarea!.value).toBe('do x')
  })

  it('renders traits as pills', () => {
    render(
      html`<${KeeperConfigPanel}
        keeper=${{ id: 'sangsu' }}
        base=${{ traits: ['calm', 'precise'] }}
      />`,
      container,
    )

    expect(container.textContent).toContain('calm')
    expect(container.textContent).toContain('precise')
  })

  it('switches the selected model', async () => {
    render(html`<${KeeperConfigPanel} keeper=${{ id: 'sangsu' }} />`, container)

    const seg = container.querySelector('[data-testid="kcp-seg"]') as HTMLElement | null
    expect(seg).not.toBeNull()
    const buttons = Array.from(seg!.querySelectorAll('button')) as HTMLButtonElement[]
    expect(buttons.length).toBe(3)

    expect(buttons[1]!.getAttribute('data-active')).toBe('true')
    await fireEvent.click(buttons[2]!)
    expect(buttons[1]!.getAttribute('data-active')).toBe('false')
    expect(buttons[2]!.getAttribute('data-active')).toBe('true')
  })

  it('toggles a permission', async () => {
    render(
      html`<${KeeperConfigPanel}
        keeper=${{ id: 'sangsu' }}
        permissions=${{ '읽기': true, '쓰기': false }}
      />`,
      container,
    )

    const toggles = Array.from(container.querySelectorAll('[data-testid="kcp-toggle"]')) as HTMLButtonElement[]
    expect(toggles.length).toBe(2)
    expect(toggles[0]!.getAttribute('aria-checked')).toBe('true')
    expect(toggles[1]!.getAttribute('aria-checked')).toBe('false')

    await fireEvent.click(toggles[1]!)
    expect(toggles[1]!.getAttribute('aria-checked')).toBe('true')
  })

  it('renders the save button', () => {
    render(html`<${KeeperConfigPanel} keeper=${{ id: 'sangsu' }} />`, container)
    const saveButton = container.querySelector('[data-testid="kcp-save"]') as HTMLButtonElement | null
    expect(saveButton).not.toBeNull()
    expect(saveButton!.textContent).toContain('저장 · 재시작 없이 적용')
  })

  it('renders overlay wrapper when asOverlay is true', () => {
    render(html`<${KeeperConfigPanel} keeper=${{ id: 'sangsu' }} asOverlay />`, container)
    expect(container.querySelector('[data-testid="kcp-overlay"]')).not.toBeNull()
  })
})
