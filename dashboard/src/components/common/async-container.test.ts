// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { signal } from '@preact/signals'
import { h } from 'preact'
import { render } from 'preact'
import { AsyncContainer } from './async-container'
import { idle, loading, loaded, failed, type AsyncState } from '../../lib/async-state'

describe('AsyncContainer', () => {
  it('renders loading state', () => {
    const container = document.createElement('div')
    const state = signal<AsyncState<string>>(loading)
    render(
      h(AsyncContainer<string>, { state, render: (d) => h('div', null, d) }),
      container,
    )
    expect(container.textContent).toContain('데이터를 불러오는 중')
  })

  it('renders custom loading message', () => {
    const container = document.createElement('div')
    const state = signal<AsyncState<string>>(loading)
    render(
      h(AsyncContainer<string>, {
        state,
        render: (d) => h('div', null, d),
        loadingMessage: 'Wait...',
      }),
      container,
    )
    expect(container.textContent).toContain('Wait...')
  })

  it('renders error state', () => {
    const container = document.createElement('div')
    const state = signal<AsyncState<string>>(failed('Network error'))
    render(
      h(AsyncContainer<string>, { state, render: (d) => h('div', null, d) }),
      container,
    )
    expect(container.textContent).toContain('Network error')
  })

  it('renders content when loaded', () => {
    const container = document.createElement('div')
    const state = signal<AsyncState<{ name: string }>>(loaded({ name: 'Alice' }))
    render(
      h(AsyncContainer<{ name: string }>, {
        state,
        render: (d) => h('div', null, d.name),
      }),
      container,
    )
    expect(container.textContent).toContain('Alice')
  })

  it('renders empty state when emptyWhen matches', () => {
    const container = document.createElement('div')
    const state = signal<AsyncState<unknown[]>>(loaded([]))
    render(
      h(AsyncContainer<unknown[]>, {
        state,
        render: () => h('div', null, 'items'),
        emptyWhen: (d) => d.length === 0,
      }),
      container,
    )
    expect(container.textContent).toContain('데이터가 없습니다')
  })

  it('renders custom empty message', () => {
    const container = document.createElement('div')
    const state = signal<AsyncState<unknown[]>>(loaded([]))
    render(
      h(AsyncContainer<unknown[]>, {
        state,
        render: () => h('div', null, 'items'),
        emptyWhen: (d) => d.length === 0,
        emptyMessage: 'Nothing here',
      }),
      container,
    )
    expect(container.textContent).toContain('Nothing here')
  })

  it('renders idle as loading', () => {
    const container = document.createElement('div')
    const state = signal<AsyncState<string>>(idle)
    render(
      h(AsyncContainer<string>, { state, render: (d) => h('div', null, d) }),
      container,
    )
    expect(container.textContent).toContain('데이터를 불러오는 중')
  })
})
