// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { ActionButton } from './button'

describe('ActionButton', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a <button type="button"> by default', () => {
    render(html`<${ActionButton}>Click me<//>`, container)
    const btn = container.querySelector('button')!
    expect(btn).toBeTruthy()
    expect(btn.getAttribute('type')).toBe('button')
    expect(btn.textContent).toBe('Click me')
  })

  it('type="submit" is forwarded (form-wiring escape hatch)', () => {
    render(html`<${ActionButton} type="submit">Go<//>`, container)
    expect(container.querySelector('button')!.getAttribute('type')).toBe('submit')
  })

  it('variant defaults to primary + classes include the accent token', () => {
    render(html`<${ActionButton}>p<//>`, container)
    const cn = container.querySelector('button')!.className
    expect(cn).toContain('accent')
  })

  it('variant=danger includes the bad-state token classes', () => {
    render(html`<${ActionButton} variant="danger">x<//>`, container)
    expect(container.querySelector('button')!.className).toContain('bad')
  })

  it('size=sm uses the smaller padding tier', () => {
    render(html`<${ActionButton} size="sm">s<//>`, container)
    expect(container.querySelector('button')!.className).toContain('py-1 px-2')
  })

  it('size=lg uses the larger padding tier', () => {
    render(html`<${ActionButton} size="lg">l<//>`, container)
    expect(container.querySelector('button')!.className).toContain('py-2 px-4')
  })

  it('block=true adds w-full', () => {
    render(html`<${ActionButton} block=${true}>b<//>`, container)
    expect(container.querySelector('button')!.className).toContain('w-full')
  })

  it('disabled=true sets the attribute and adds the muted opacity class', () => {
    render(html`<${ActionButton} disabled=${true}>d<//>`, container)
    const btn = container.querySelector('button') as HTMLButtonElement
    expect(btn.disabled).toBe(true)
    expect(btn.className).toContain('opacity-50')
    expect(btn.className).toContain('pointer-events-none')
  })

  it('onClick fires when clicked', () => {
    const spy = vi.fn()
    render(html`<${ActionButton} onClick=${spy}>go<//>`, container)
    ;(container.querySelector('button') as HTMLButtonElement).click()
    expect(spy).toHaveBeenCalledOnce()
  })

  it('aria-label is forwarded', () => {
    render(html`<${ActionButton} ariaLabel="cancel task">×<//>`, container)
    expect(container.querySelector('button')!.getAttribute('aria-label')).toBe('cancel task')
  })

  it('id is forwarded (label-for / programmatic focus contract)', () => {
    render(html`<${ActionButton} id="save-btn">Save<//>`, container)
    expect(container.querySelector('button')!.id).toBe('save-btn')
  })

  it('ariaBusy=true is forwarded as aria-busy="true" for AT announcements', () => {
    render(html`<${ActionButton} ariaBusy=${true} disabled=${true}>Saving...<//>`, container)
    expect(container.querySelector('button')!.getAttribute('aria-busy')).toBe('true')
  })

  it('ariaBusy=false / unset does NOT render the aria-busy attribute', () => {
    render(html`<${ActionButton}>Save<//>`, container)
    expect(container.querySelector('button')!.hasAttribute('aria-busy')).toBe(false)
  })

  it('title is forwarded for native hover tooltip', () => {
    render(html`<${ActionButton} title="Delete connector">✕<//>`, container)
    expect(container.querySelector('button')!.getAttribute('title')).toBe('Delete connector')
  })

  it('testId is forwarded as data-testid (E2E stable hook)', () => {
    render(html`<${ActionButton} testId="connector-save">save<//>`, container)
    expect(container.querySelector('button')!.getAttribute('data-testid')).toBe('connector-save')
  })

  it('extra `class` prop is appended to the variant/size/base classes', () => {
    render(html`<${ActionButton} class="extra-hook">x<//>`, container)
    expect(container.querySelector('button')!.className).toContain('extra-hook')
  })
})
