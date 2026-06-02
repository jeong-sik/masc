// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useControllableState } from './use-controllable-state'

function UncontrolledTester({ defaultProp, onChange }: { defaultProp: string; onChange?: (v: string) => void }) {
  const [value, setValue] = useControllableState({ defaultProp, onChange })
  return html`
    <div data-value=${value}>
      <button onClick=${() => setValue('updated')}>Update</button>
    </div>
  `
}

function ControlledTester({ prop, onChange }: { prop: string; onChange?: (v: string) => void }) {
  const [value, setValue] = useControllableState({ prop, onChange })
  return html`
    <div data-value=${value}>
      <button onClick=${() => setValue('updated')}>Update</button>
    </div>
  `
}

describe('useControllableState', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('uses defaultProp when uncontrolled', () => {
    render(html`<${UncontrolledTester} defaultProp="initial" />`, container)
    const el = container.querySelector('div') as HTMLElement
    expect(el.getAttribute('data-value')).toBe('initial')
  })

  it('updates internal state when uncontrolled', async () => {
    render(html`<${UncontrolledTester} defaultProp="initial" />`, container)
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    const el = container.querySelector('div') as HTMLElement
    expect(el.getAttribute('data-value')).toBe('updated')
  })

  it('uses prop when controlled', () => {
    render(html`<${ControlledTester} prop="controlled" />`, container)
    const el = container.querySelector('div') as HTMLElement
    expect(el.getAttribute('data-value')).toBe('controlled')
  })

  it('calls onChange when uncontrolled', () => {
    const onChange = vi.fn()
    render(html`<${UncontrolledTester} defaultProp="a" onChange=${onChange} />`, container)
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.click()
    expect(onChange).toHaveBeenCalledWith('updated')
  })

  it('calls onChange when controlled', () => {
    const onChange = vi.fn()
    render(html`<${ControlledTester} prop="a" onChange=${onChange} />`, container)
    const btn = container.querySelector('button') as HTMLButtonElement
    btn.click()
    expect(onChange).toHaveBeenCalledWith('updated')
  })
})
