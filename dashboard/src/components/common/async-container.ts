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
import { EmptyState } from './empty-state'

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
      return html`<${EmptyState} message=${loadingMessage} />`

    case 'error':
      return html`
        <div class="px-4 py-3 rounded-lg bg-red-500/10 border border-red-500/20 text-red-400 text-[length:var(--fs-sm)]">
          ${s.message}
        </div>
      `

    case 'loaded':
      if (emptyWhen?.(s.data)) {
        return html`<${EmptyState} message=${emptyMessage} />`
      }
      return render(s.data)
  }
}
