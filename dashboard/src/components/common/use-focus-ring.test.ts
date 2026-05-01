import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { useFocusRing } from './use-focus-ring'

function FocusRingUser() {
  const { focusRingProps, focused, focusVisible } = useFocusRing()
  return h('button', { ...focusRingProps, 'data-focused': focused ? 'true' : undefined, 'data-focus-visible': focusVisible ? 'true' : undefined }, 'Btn')
}

describe('useFocusRing', () => {
  it('returns focused=false and focusVisible=false initially', () => {
    const container = document.createElement('div')
    render(h(FocusRingUser, null), container)
    const btn = container.querySelector('button')
    expect(btn?.getAttribute('data-focused')).toBeNull()
    expect(btn?.getAttribute('data-focus-visible')).toBeNull()
  })

  it('sets focused on focus', async () => {
    const container = document.createElement('div')
    render(h(FocusRingUser, null), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new FocusEvent('focus', { relatedTarget: null }))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-focused')).toBe('true')
  })

  it('sets focusVisible when relatedTarget is null', async () => {
    const container = document.createElement('div')
    render(h(FocusRingUser, null), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new FocusEvent('focus', { relatedTarget: null }))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-focus-visible')).toBe('true')
  })

  it('clears focused and focusVisible on blur', async () => {
    const container = document.createElement('div')
    render(h(FocusRingUser, null), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.dispatchEvent(new FocusEvent('focus', { relatedTarget: null }))
    await new Promise((r) => setTimeout(r, 0))
    btn.dispatchEvent(new FocusEvent('blur'))
    await new Promise((r) => setTimeout(r, 0))
    expect(btn.getAttribute('data-focused')).toBeNull()
    expect(btn.getAttribute('data-focus-visible')).toBeNull()
  })
})
