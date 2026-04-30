import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Log } from './log'

describe('Log', () => {
  it('renders role=log', () => {
    const container = document.createElement('div')
    render(h(Log, {}, 'Message'), container)
    expect(container.querySelector('[role="log"]')).not.toBeNull()
  })

  it('renders children', () => {
    const container = document.createElement('div')
    render(h(Log, {}, 'Hello log'), container)
    expect(container.textContent).toContain('Hello log')
  })

  it('applies aria-label', () => {
    const container = document.createElement('div')
    render(h(Log, { 'aria-label': 'activity log' }, 'X'), container)
    const el = container.querySelector('[role="log"]')
    expect(el?.getAttribute('aria-label')).toBe('activity log')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(Log, { class: 'my-log' }, 'X'), container)
    const el = container.querySelector('[role="log"]')
    expect(el?.classList.contains('my-log')).toBe(true)
  })
})
