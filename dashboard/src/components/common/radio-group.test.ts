// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { RadioGroup, Radio } from './radio-group'

describe('RadioGroup', () => {
  it('renders radiogroup role', () => {
    const container = document.createElement('div')
    render(
      h(RadioGroup, { name: 'fruit' },
        h(Radio, { value: 'a' }, 'Apple'),
      ),
      container,
    )
    expect(container.querySelector('[role="radiogroup"]')).not.toBeNull()
  })

  it('renders radio items', () => {
    const container = document.createElement('div')
    render(
      h(RadioGroup, { name: 'fruit' },
        h(Radio, { value: 'a' }, 'Apple'),
        h(Radio, { value: 'b' }, 'Banana'),
      ),
      container,
    )
    const radios = container.querySelectorAll('[role="radio"]')
    expect(radios.length).toBe(2)
    expect(container.textContent).toContain('Apple')
    expect(container.textContent).toContain('Banana')
  })

  it('selects item on click', async () => {
    const container = document.createElement('div')
    render(
      h(RadioGroup, { name: 'fruit', defaultValue: 'a' },
        h(Radio, { value: 'a' }, 'Apple'),
        h(Radio, { value: 'b' }, 'Banana'),
      ),
      container,
    )
    const radios = container.querySelectorAll('[role="radio"]')
    ;(radios[1] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(radios[1]?.getAttribute('aria-checked')).toBe('true')
    expect(radios[0]?.getAttribute('aria-checked')).toBe('false')
  })

  it('calls onValueChange on click', async () => {
    const onValueChange = vi.fn()
    const container = document.createElement('div')
    render(
      h(RadioGroup, { name: 'fruit', onValueChange },
        h(Radio, { value: 'a' }, 'Apple'),
        h(Radio, { value: 'b' }, 'Banana'),
      ),
      container,
    )
    const radios = container.querySelectorAll('[role="radio"]')
    ;(radios[1] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onValueChange).toHaveBeenCalledWith('b')
  })

  it('applies tabindex=0 to selected and -1 to others', () => {
    const container = document.createElement('div')
    render(
      h(RadioGroup, { name: 'fruit', defaultValue: 'b' },
        h(Radio, { value: 'a' }, 'Apple'),
        h(Radio, { value: 'b' }, 'Banana'),
      ),
      container,
    )
    const radios = container.querySelectorAll('[role="radio"]')
    expect(radios[0]?.getAttribute('tabindex')).toBe('-1')
    expect(radios[1]?.getAttribute('tabindex')).toBe('0')
  })

  it('works with controlled value', () => {
    const container = document.createElement('div')
    render(
      h(RadioGroup, { name: 'fruit', value: 'a' },
        h(Radio, { value: 'a' }, 'Apple'),
        h(Radio, { value: 'b' }, 'Banana'),
      ),
      container,
    )
    const radios = container.querySelectorAll('[role="radio"]')
    expect(radios[0]?.getAttribute('aria-checked')).toBe('true')
    expect(radios[1]?.getAttribute('aria-checked')).toBe('false')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(
      h(RadioGroup, { name: 'fruit', class: 'my-group' },
        h(Radio, { value: 'a' }, 'Apple'),
      ),
      container,
    )
    const group = container.querySelector('[role="radiogroup"]')
    expect(group?.classList.contains('my-group')).toBe(true)
  })
})
