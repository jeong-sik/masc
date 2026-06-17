// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { ChatStatusDot, ChatSigilBadge, ChatSuggestionChip } from './primitives'

describe('keeper-v2 chat primitive wrappers', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('ChatStatusDot maps run -> ok tone', () => {
    render(html`<${ChatStatusDot} status="run" />`, container)
    const el = container.querySelector('[data-status-dot]') as HTMLElement
    expect(el).not.toBeNull()
    expect(el.className).toContain('bg-[var(--color-status-ok)]')
    expect(el.getAttribute('aria-label')).toBe('ok')
  })

  it('ChatStatusDot maps pause -> warn and idle -> idle', () => {
    render(html`<${ChatStatusDot} status="pause" pulse=${true} />`, container)
    const el = container.querySelector('[data-status-dot]') as HTMLElement
    expect(el.className).toContain('bg-[var(--color-status-warn)]')
    expect(el.className).toContain('animate-pulse')
  })

  it('ChatSigilBadge renders monogram and title from keeper id', () => {
    render(html`<${ChatSigilBadge} k=${{ slot: 3, id: 'iron-claw', sigil: 'IC' }} />`, container)
    const el = container.querySelector('.sigil') as HTMLElement
    expect(el).not.toBeNull()
    expect(el.textContent).toBe('IC')
    expect(el.getAttribute('title')).toBe('iron-claw')
    expect(el.getAttribute('aria-label')).toBe('iron-claw')
    expect(el.style.getPropertyValue('--kc')).toBe('var(--kp3)')
  })

  it('ChatSuggestionChip delegates to shared SuggestionChip', () => {
    const onClick = vi.fn()
    render(html`<${ChatSuggestionChip} pre="\u203A" onClick=${onClick}>Pick me<//>`, container)
    const el = container.querySelector('.suggestion-chip') as HTMLElement
    expect(el).not.toBeNull()
    expect(el.textContent).toContain('Pick me')
    expect(container.querySelector('.suggestion-chip-pre')?.textContent).toBe('\u203A')
    el.click()
    expect(onClick).toHaveBeenCalledTimes(1)
  })
})
