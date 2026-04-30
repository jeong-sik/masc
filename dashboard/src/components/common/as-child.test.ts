import { describe, expect, it } from 'vitest'
import { h, type VNode } from 'preact'
import { asChildClone, mergeProps } from './as-child'

describe('mergeProps', () => {
  it('merges simple props', () => {
    const result = mergeProps({ a: 1 }, { b: 2 })
    expect(result).toEqual({ a: 1, b: 2 })
  })

  it('child overrides parent for plain keys', () => {
    const result = mergeProps({ id: 'child' }, { id: 'parent' })
    expect(result.id).toBe('child')
  })

  it('concatenates class and className', () => {
    const result = mergeProps(
      { class: 'child-class', className: 'child-cn' },
      { class: 'parent-class', className: 'parent-cn' }
    )
    expect(result.class).toBe('child-class parent-class')
    expect(result.className).toBe('child-cn parent-cn')
  })

  it('uses child class when parent has none', () => {
    const result = mergeProps({ class: 'child-class' }, {})
    expect(result.class).toBe('child-class')
  })

  it('chains onClick handlers', () => {
    const childFn = vi.fn()
    const parentFn = vi.fn()
    const result = mergeProps({ onClick: childFn }, { onClick: parentFn })

    expect(typeof result.onClick).toBe('function')
    const ev = new Event('click')
    ;(result.onClick as (e: Event) => void)(ev)
    expect(childFn).toHaveBeenCalledTimes(1)
    expect(parentFn).toHaveBeenCalledTimes(1)
  })

  it('keeps child handler when parent has none', () => {
    const childFn = vi.fn()
    const result = mergeProps({ onClick: childFn }, {})
    expect(result.onClick).toBe(childFn)
  })

  it('keeps non-function on-prefixed keys as-is', () => {
    const result = mergeProps({ onSomething: 'not-a-fn' }, { onSomething: 42 })
    expect(result.onSomething).toBe('not-a-fn')
  })
})

describe('asChildClone', () => {
  it('clones a VNode and merges props', () => {
    const child = h('button', { type: 'button', class: 'base' }, 'Click')
    const cloned = asChildClone(child, { class: 'extra', 'data-testid': 'btn' })

    expect(cloned.type).toBe('button')
    expect((cloned.props as Record<string, unknown>).type).toBe('button')
    expect((cloned.props as Record<string, unknown>).class).toBe('base extra')
    expect((cloned.props as Record<string, unknown>)['data-testid']).toBe('btn')
  })

  it('wraps non-element children in a span', () => {
    const wrapped = asChildClone('plain text', { class: 'wrapper' })
    expect(wrapped.type).toBe('span')
    expect((wrapped.props as Record<string, unknown>).class).toBe('wrapper')
  })

  it('wraps null children in a span', () => {
    const wrapped = asChildClone(null, { id: 'fallback' })
    expect(wrapped.type).toBe('span')
    expect((wrapped.props as Record<string, unknown>).id).toBe('fallback')
  })

  it('wraps array children in a span', () => {
    const wrapped = asChildClone(['a', 'b'], { class: 'arr' })
    expect(wrapped.type).toBe('span')
  })

  it('chains handlers when both child and parent provide onClick', () => {
    const childFn = vi.fn()
    const parentFn = vi.fn()
    const child = h('div', { onClick: childFn })
    const cloned = asChildClone(child, { onClick: parentFn })

    const ev = new Event('click')
    ;((cloned.props as Record<string, unknown>).onClick as (e: Event) => void)(ev)
    expect(childFn).toHaveBeenCalledTimes(1)
    expect(parentFn).toHaveBeenCalledTimes(1)
  })
})
