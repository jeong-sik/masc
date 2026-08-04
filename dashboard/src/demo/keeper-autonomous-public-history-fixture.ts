import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/keeper-workspace.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { ChatTranscript } from '../components/chat/primitives'
import { chatHistoryEntriesFromRest } from '../keeper-state'

const rawHistory = [
  {
    id: 'autonomous:trace-fixture#1',
    role: 'assistant',
    content: 'Checked the board; no action was required.',
    ts: 1785770777,
    autonomous_turn: {
      turn_id: 'trace-fixture#1',
      agent_name: 'fixture-agent',
      generation: 4,
      blocks: [
        { kind: 'thinking', content: 'PRIVATE_THINKING_MUST_NOT_RENDER' },
        { kind: 'tool_use', name: 'Read', input: { token: 'PRIVATE_TOOL_ARG' } },
      ],
    },
  },
  {
    id: 'autonomous:trace-fixture#2',
    role: 'assistant',
    content: 'Observed one healthy follow-up.',
    ts: 1785770837,
    autonomous_turn: {
      turn_id: 'trace-fixture#2',
      agent_name: 'fixture-agent',
      generation: 4,
    },
  },
]

const entries = chatHistoryEntriesFromRest('fixture-keeper', rawHistory)
const fixtureStatus =
  entries.length === 2
  && entries.every(entry => entry.traceSteps === undefined)
  && entries.map(entry => entry.turnRef).join('|') === 'trace-fixture#1|trace-fixture#2'
    ? 'ok'
    : 'invalid'

function AutonomousPublicHistoryFixture() {
  return html`
    <main
      class="min-h-screen px-4 py-8"
      style="background: var(--bg-deep);"
      data-autonomous-public-history-fixture
      data-autonomous-public-history-fixture-status=${fixtureStatus}
    >
      <section class="mx-auto max-w-[820px]">
        <header class="mb-5">
          <p class="font-mono text-2xs uppercase tracking-[0.2em]" style="color: var(--text-dim);">
            Keeper Autonomous Public History Contract
          </p>
          <h1 class="mt-2 text-xl font-semibold" style="color: var(--text-main);">
            Public outcomes only
          </h1>
        </header>
        <div
          class="kw-chat rounded-[var(--r-2)] border p-4"
          style="background: var(--bg-panel); border-color: var(--border-main);"
        >
          <${ChatTranscript}
            entries=${entries}
            emptyText="No autonomous rows"
            variant="messenger"
            size="primary"
            showMetadata=${false}
            groupToolCalls=${true}
          />
        </div>
      </section>
    </main>
  `
}

const root = document.getElementById('app')
if (root) render(html`<${AutonomousPublicHistoryFixture} />`, root)
