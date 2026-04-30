// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { RadioGroup, Radio } from './radio-group'

describe('RadioGroup a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly', async () => {
    render(
      html`<${RadioGroup} name="theme" defaultValue="dark">
        <${Radio} value="light">Light<//>
        <${Radio} value="dark">Dark<//>
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has radiogroup role with aria-label', () => {
    render(
      html`<${RadioGroup} name="theme" defaultValue="dark">
        <${Radio} value="light">Light<//>
      <//>`,
      container,
    )
    const group = container.querySelector('[role="radiogroup"]') as HTMLElement
    expect(group).not.toBeNull()
    expect(group.getAttribute('aria-label')).toBe('theme')
  })

  it('radio has aria-checked reflecting selection', () => {
    render(
      html`<${RadioGroup} name="theme" defaultValue="dark">
        <${Radio} value="light">Light<//>
        <${Radio} value="dark">Dark<//>
      <//>`,
      container,
    )
    const radios = container.querySelectorAll('[role="radio"]')
    expect(radios[0]!.getAttribute('aria-checked')).toBe('false')
    expect(radios[1]!.getAttribute('aria-checked')).toBe('true')
  })

  it('selects on click', async () => {
    const onChange = vi.fn()
    render(
      html`<${RadioGroup} name="theme" defaultValue="dark" onValueChange=${onChange}>
        <${Radio} value="light">Light<//>
        <${Radio} value="dark">Dark<//>
      <//>`,
      container,
    )
    const radios = container.querySelectorAll('[role="radio"]')
    ;(radios[0]! as HTMLDivElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).toHaveBeenCalledWith('light')
    expect(radios[0]!.getAttribute('aria-checked')).toBe('true')
    expect(radios[1]!.getAttribute('aria-checked')).toBe('false')
  })

  it('ArrowDown moves focus and selects next', async () => {
    render(
      html`<${RadioGroup} name="theme" defaultValue="light">
        <${Radio} value="light">Light<//>
        <${Radio} value="dark">Dark<//>
      <//>`,
      container,
    )
    const radios = container.querySelectorAll('[role="radio"]')
    ;(radios[0]! as HTMLDivElement).focus()
    radios[0]!.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(document.activeElement).toBe(radios[1])
    expect(radios[1]!.getAttribute('aria-checked')).toBe('true')
  })
})
