import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Vital, Vitals } from './vital'

describe('Vital', () => {
  it('renders key and value', () => {
    const container = document.createElement('div')
    render(html`<${Vital} k="Context" v="68%" />`, container)
    expect(container.textContent).toContain('Context')
    expect(container.textContent).toContain('68%')
  })

  it('applies tone class', () => {
    const container = document.createElement('div')
    render(html`<${Vital} k="Context" v="68%" tone="volt" />`, container)
    const el = container.querySelector('.vv')
    expect(el?.classList.contains('volt')).toBe(true)
  })
})

describe('Vitals', () => {
  const items = [
    { k: 'Turn', v: '#142' },
    { k: 'Model', v: 'sonnet-4.5' },
    { k: 'Cost', v: '$0.42', tone: 'volt' as const },
  ]

  it('renders all items', () => {
    const container = document.createElement('div')
    render(html`<${Vitals} items=${items} />`, container)
    expect(container.textContent).toContain('Turn')
    expect(container.textContent).toContain('Model')
    expect(container.textContent).toContain('Cost')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(html`<${Vitals} items=${items} class="my-vitals" />`, container)
    const el = container.querySelector('.vitals')
    expect(el?.classList.contains('my-vitals')).toBe(true)
  })
})
