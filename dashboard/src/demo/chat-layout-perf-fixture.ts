import { html } from 'htm/preact'
import { render } from 'preact'
import { ChatTranscript } from '../components/chat/primitives'
import type { KeeperConversationEntry } from '../types'

// Browser-only workload. No provider calls, store mutations, or server writes.
export function mountChatLayoutPerfFixture(root: HTMLElement) {
  const entry = (index: number, text: string): KeeperConversationEntry => ({
    id: `layout-${index}`,
    role: 'assistant',
    source: 'direct_assistant',
    label: 'Layout fixture',
    text,
    rawText: text,
    timestamp: new Date(Date.UTC(2026, 0, 1, 0, 0, index)).toISOString(),
    delivery: 'history',
    streamState: null,
    details: null,
    error: null,
  })
  let entries = Array.from({ length: 400 }, (_, i) => entry(i,
    `Message ${i}. ` + 'A measured conversation row retains its text and actions. '.repeat(12),
  ))
  entries.push({ ...entry(400, ''), blocks: [{
    t: 'svg',
    svg: '<svg viewBox="0 0 320 160"><rect width="320" height="160" fill="#275a86"/><text x="20" y="85" fill="white">Preview fixture</text></svg>',
    cap: 'Layout preview',
  }] })
  const draw = () => render(html`<${ChatTranscript}
    entries=${entries} emptyText="No messages" size="primary"
  />`, root)
  draw()
  return {
    append() {
      entries = [...entries, entry(entries.length, 'A new message arrived while reading.')]
      draw()
    },
    growLast() {
      const last = entries.at(-1)!
      entries = [...entries.slice(0, -1), { ...last, text: last.text + '\nMore streamed text.'.repeat(20) }]
      draw()
    },
    short() { entries = [entry(0, 'One short message.')]; draw() },
    clear() { entries = []; draw() },
    unmount() { render(null, root) },
  }
}
