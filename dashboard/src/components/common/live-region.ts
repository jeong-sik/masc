// LiveRegion — aria-live region manager for agent output accessibility.
//
// Kimi design system sec06 6.2.1: polite vs assertive live regions.
// Screen-reader-only divs route agent messages to assistive tech without
// affecting visual layout. Polite messages queue; assertive messages interrupt.

import { html } from 'htm/preact'

interface LiveMessage {
  id: string
  text: string
  priority: 'polite' | 'assertive'
}

interface LiveRegionProps {
  messages: LiveMessage[]
  testId?: string
}

export function LiveRegion({ messages, testId }: LiveRegionProps) {
  const polite = messages.filter((m) => m.priority === 'polite')
  const assertive = messages.filter((m) => m.priority === 'assertive')

  return html`
    <div data-live-region data-testid=${testId} class="sr-only">
      <div aria-live="polite" aria-atomic="false">
        ${polite.map((m) => html`<div key=${m.id}>${m.text}</div>`)}
      </div>
      <div aria-live="assertive" aria-atomic="true">
        ${assertive.map((m) => html`<div key=${m.id}>${m.text}</div>`)}
      </div>
    </div>
  `
}
