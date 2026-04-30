import { describe, expect, it } from 'vitest'
import { signal } from '@preact/signals'
import { h } from 'preact'
import { render } from 'preact'
import { AsyncContainer } from './async-container'
import { idle, loading, loaded, failed } from '../../lib/async-state'

describe('AsyncContainer', () => {
  it('renders loading state', () => {
    const container = document.createElement('div')
    const state = signal(loading)
    render(
      h(AsyncContainer, { state, render: (d: string) => h('div', null, d) }),
      container,
    )
    expect(container.textContent).toContain('데이터를 불러오는 중')
  })

  it('renders custom loading message', () => {
    const container = document.createElement('div')
    const state = signal(loading)
    render(
      h(AsyncContainer, {
        state,
        render: (d: string) => h('div', null, d),
        loadingMessage: 'Wait...',
      }),
      container,
    )
    expect(container.textContent).toContain('Wait...')
  })

  it('renders error state', () => {
    const container = document.createElement('div')
    const state = signal(failed('Network error'))
    render(
      h(AsyncContainer, { state, render: (d: string) => h('div', null, d) }),
      container,
    )
    expect(container.textContent).toContain('Network error')
  })

  it('renders content when loaded', () => {
    const container = document.createElement('div')
    const state = signal(loaded({ name: 'Alice' }))
    render(
      h(AsyncContainer, {
        state,
        render: (d: { name: string }) => h('div', null, d.name),
      }),
      container,
    )
    expect(container.textContent).toContain('Alice')
  })

  it('renders empty state when emptyWhen matches', () => {
    const container = document.createElement('div')
    const state = signal(loaded([]))
    render(
      h(AsyncContainer, {
        state,
        render: (d: unknown[]) => h('div', null, 'items'),
        emptyWhen: (d: unknown[]) => d.length === 0,
      }),
      container,
    )
    expect(container.textContent).toContain('데이터가 없습니다')
  })

  it('renders custom empty message', () => {
    const container = document.createElement('div')
    const state = signal(loaded([]))
    render(
      h(AsyncContainer, {
        state,
        render: (d: unknown[]) => h('div', null, 'items'),
        emptyWhen: (d: unknown[]) => d.length === 0,
        emptyMessage: 'Nothing here',
      }),
      container,
    )
    expect(container.textContent).toContain('Nothing here')
  })

  it('renders idle as loading', () => {
    const container = document.createElement('div')
    const state = signal(idle)
    render(
      h(AsyncContainer, { state, render: (d: string) => h('div', null, d) }),
      container,
    )
    expect(container.textContent).toContain('데이터를 불러오는 중')
  })
})
