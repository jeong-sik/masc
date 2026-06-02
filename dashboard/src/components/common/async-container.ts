// AsyncContainer — renders loading/error/empty/content based on AsyncState.
// Eliminates the repeated if-loading/if-error/if-empty branching in 15+ components.
//
// Usage:
//   html`<${AsyncContainer}
//     state=${resource.state}
//     render=${(data) => html`<div>${data.items.map(...)}</div>`}
//     emptyWhen=${(d) => d.items.length === 0}
//   />`

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import type { Signal } from '@preact/signals'
import type { AsyncState } from '../../lib/async-state'
import { EmptyState, ErrorState, LoadingState } from './feedback-state'

interface AsyncContainerProps<T> {
  state: Signal<AsyncState<T>>
  render: (data: T) => ComponentChildren
  loadingMessage?: string
  emptyWhen?: (data: T) => boolean
  emptyMessage?: string
}

export function AsyncContainer<T>({
  state: stateSignal,
  render,
  loadingMessage = '데이터를 불러오는 중...',
  emptyWhen,
  emptyMessage = '데이터가 없습니다.',
}: AsyncContainerProps<T>) {
  const s = stateSignal.value

  switch (s.status) {
    case 'idle':
    case 'loading':
      return html`<${LoadingState}>${loadingMessage}<//>`

    case 'error':
      return html`<${ErrorState} message=${s.message} />`

    case 'loaded':
      if (emptyWhen?.(s.data)) {
        return html`<${EmptyState} message=${emptyMessage} />`
      }
      return render(s.data)
  }
}
