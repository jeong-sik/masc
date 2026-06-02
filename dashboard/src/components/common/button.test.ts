// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { ActionButton, summarizeActionButton } from './button'

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
    expect(btn.hasAttribute('data-action-button')).toBe(true)
    expect(btn.getAttribute('data-action-button-variant')).toBe('primary')
    expect(btn.getAttribute('data-action-button-size')).toBe('md')
    expect(btn.getAttribute('data-action-button-type')).toBe('button')
    expect(btn.getAttribute('data-action-button-pressed-state')).toBe('unset')
    expect(btn.getAttribute('data-action-button-has-children')).toBe('true')
  })

  it('type="submit" is forwarded (form-wiring escape hatch)', () => {
    render(html`<${ActionButton} type="submit">Go<//>`, container)
    const btn = container.querySelector('button')!
    expect(btn.getAttribute('type')).toBe('submit')
    expect(btn.getAttribute('data-action-button-type')).toBe('submit')
  })

  it('variant defaults to primary + classes include the accent token', () => {
    render(html`<${ActionButton}>p<//>`, container)
    const cn = container.querySelector('button')!.className
    expect(cn).toContain('accent')
  })

  it('variant=danger includes the danger token classes', () => {
    render(html`<${ActionButton} variant="danger">x<//>`, container)
    // After cycle 34 the inline `bad-*` literals were swapped for the
    // `--button-danger-*` component-level aliases; var() chain resolves
    // to the same hex (zero visual drift).
    expect(container.querySelector('button')!.className).toContain('button-danger')
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
    const btn = container.querySelector('button')!
    expect(btn.className).toContain('w-full')
    expect(btn.getAttribute('data-action-button-block')).toBe('true')
  })

  it('disabled=true sets the attribute and adds the muted opacity class', () => {
    render(html`<${ActionButton} disabled=${true}>d<//>`, container)
    const btn = container.querySelector('button') as HTMLButtonElement
    expect(btn.disabled).toBe(true)
    expect(btn.className).toContain('opacity-50')
    expect(btn.className).toContain('pointer-events-none')
    expect(btn.getAttribute('data-action-button-disabled')).toBe('true')
  })

  it('onClick fires when clicked', () => {
    const spy = vi.fn()
    render(html`<${ActionButton} onClick=${spy}>go<//>`, container)
    const btn = container.querySelector('button') as HTMLButtonElement
    expect(btn.getAttribute('data-action-button-has-click-handler')).toBe('true')
    btn.click()
    expect(spy).toHaveBeenCalledOnce()
  })

  it('aria-label is forwarded', () => {
    render(html`<${ActionButton} ariaLabel="cancel task">×<//>`, container)
    const btn = container.querySelector('button')!
    expect(btn.getAttribute('aria-label')).toBe('cancel task')
    expect(btn.getAttribute('data-action-button-has-aria-label')).toBe('true')
    expect(btn.getAttribute('data-action-button-aria-label-length')).toBe('11')
  })

  it('id is forwarded (label-for / programmatic focus contract)', () => {
    render(html`<${ActionButton} id="save-btn">Save<//>`, container)
    const btn = container.querySelector('button')!
    expect(btn.id).toBe('save-btn')
    expect(btn.getAttribute('data-action-button-has-id')).toBe('true')
    expect(btn.getAttribute('data-action-button-id-length')).toBe('8')
  })

  it('ariaBusy=true is forwarded as aria-busy="true" for AT announcements', () => {
    render(html`<${ActionButton} ariaBusy=${true} disabled=${true}>Saving...<//>`, container)
    const btn = container.querySelector('button')!
    expect(btn.getAttribute('aria-busy')).toBe('true')
    expect(btn.getAttribute('data-action-button-busy')).toBe('true')
  })

  it('ariaBusy=false / unset does NOT render the aria-busy attribute', () => {
    render(html`<${ActionButton}>Save<//>`, container)
    expect(container.querySelector('button')!.hasAttribute('aria-busy')).toBe(false)
  })

  it('title is forwarded for native hover tooltip', () => {
    render(html`<${ActionButton} title="Delete connector">✕<//>`, container)
    const btn = container.querySelector('button')!
    expect(btn.getAttribute('title')).toBe('Delete connector')
    expect(btn.getAttribute('data-action-button-has-title')).toBe('true')
    expect(btn.getAttribute('data-action-button-title-length')).toBe('16')
  })

  it('testId is forwarded as data-testid (E2E stable hook)', () => {
    render(html`<${ActionButton} testId="connector-save">save<//>`, container)
    const btn = container.querySelector('button')!
    expect(btn.getAttribute('data-testid')).toBe('connector-save')
    expect(btn.getAttribute('data-action-button-has-test-id')).toBe('true')
    expect(btn.getAttribute('data-action-button-test-id-length')).toBe('14')
  })

  it('extra `class` prop is appended to the variant/size/base classes', () => {
    render(html`<${ActionButton} class="extra-hook">x<//>`, container)
    const btn = container.querySelector('button')!
    expect(btn.className).toContain('extra-hook')
    expect(btn.getAttribute('data-action-button-has-custom-class')).toBe('true')
    expect(btn.getAttribute('data-action-button-class-length')).toBe('10')
  })

  it('pressed=true renders aria-pressed="true" for AT (toggle/tab semantic)', () => {
    render(html`<${ActionButton} pressed=${true}>Filter<//>`, container)
    const btn = container.querySelector('button')!
    expect(btn.getAttribute('aria-pressed')).toBe('true')
    expect(btn.getAttribute('data-action-button-pressed-state')).toBe('true')
  })

  it('pressed=false renders aria-pressed="false" (button is in toggle group, currently inactive)', () => {
    render(html`<${ActionButton} pressed=${false}>Filter<//>`, container)
    const btn = container.querySelector('button')!
    expect(btn.getAttribute('aria-pressed')).toBe('false')
    expect(btn.getAttribute('data-action-button-pressed-state')).toBe('false')
  })

  it('pressed unset does NOT render aria-pressed (plain action button)', () => {
    render(html`<${ActionButton}>Save<//>`, container)
    expect(container.querySelector('button')!.hasAttribute('aria-pressed')).toBe(false)
  })

  it('pressed=true with ghost variant swaps bg to ghost-pressed slot (visual selected state)', () => {
    render(html`<${ActionButton} variant="ghost" pressed=${true}>Active<//>`, container)
    // After cycle 34 the inline accent-12 literal moved into the
    // --button-ghost-bg-pressed component slot (which itself resolves
    // to var(--accent-12) via the token chain).
    expect(container.querySelector('button')!.className).toContain('button-ghost-bg-pressed')
  })

  it('summarizes default button state', () => {
    expect(summarizeActionButton({ children: 'Save' })).toEqual({
      variant: 'primary',
      size: 'md',
      type: 'button',
      block: false,
      disabled: false,
      busy: false,
      pressedState: 'unset',
      hasCustomClass: false,
      classNameLength: 0,
      hasId: false,
      idLength: 0,
      hasAriaLabel: false,
      ariaLabelLength: 0,
      hasTitle: false,
      titleLength: 0,
      hasTestId: false,
      testIdLength: 0,
      hasOnClick: false,
      hasChildren: true,
    })
  })

  it('summarizes populated button state', () => {
    expect(summarizeActionButton({
      variant: 'warn',
      size: 'lg',
      type: 'submit',
      class: 'extra-hook',
      id: 'save-btn',
      disabled: true,
      block: true,
      ariaLabel: 'Save changes',
      ariaBusy: true,
      pressed: false,
      title: 'Save connector',
      testId: 'connector-save',
      onClick: vi.fn(),
      children: 'Save',
    })).toEqual({
      variant: 'warn',
      size: 'lg',
      type: 'submit',
      block: true,
      disabled: true,
      busy: true,
      pressedState: 'false',
      hasCustomClass: true,
      classNameLength: 10,
      hasId: true,
      idLength: 8,
      hasAriaLabel: true,
      ariaLabelLength: 12,
      hasTitle: true,
      titleLength: 14,
      hasTestId: true,
      testIdLength: 14,
      hasOnClick: true,
      hasChildren: true,
    })
  })
})
