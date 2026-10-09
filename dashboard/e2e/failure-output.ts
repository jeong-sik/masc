import '../src/styles/ds-theme-tokens.css'
import '../src/styles/primitives.css'
import '../src/styles/layout.css'
import '../src/styles/layers.css'
import '../src/styles/kpi.css'
import '../src/styles/rail.css'
import '../src/styles/deck.css'
import '../src/styles/drawer.css'
import '../src/styles/swimlanes.css'
import '../src/styles/code.css'
import '../src/styles/styleseed-theme.css'
import '../src/styles/styleseed-base.css'
import '../src/styles/global.css'
import '../src/styles/tokens.css'
import '../src/styles/paper-theme.css'
import '../src/styles/keeper-workspace.css'
import '../src/styles/copilot-dock.css'
import '../src/styles/states.css'
import '../src/styles/ss-keeper-v2-bridge.css'
import.meta.glob('../src/styles/*-v2.css', { eager: true })
import '../src/styles/keeper-v2/colors_and_type.css'
import '../src/styles/keeper-v2/v2.css'
import '../src/styles/keeper-v2/surfaces.css'
import '../src/styles/keeper-v2/dock.css'
import '../src/styles/keeper-v2/craft.css'
import '../src/styles/keeper-v2/inspector.css'
import '../src/styles/keeper-v2/perf.css'
import '../src/styles/keeper-v2/fleet.css'
import '../src/styles/keeper-v2/logs.css'
import '../src/styles/keeper-v2/keeper-config.css'
import '../src/styles/keeper-v2/fusion.css'
import '../src/styles/keeper-v2/memory.css'
import '../src/styles/keeper-v2/schedule.css'
import '../src/styles/keeper-v2/runtime.css'
import '../src/styles/keeper-v2/ops-cluster.css'
import '../src/styles/keeper-v2/prompt-book.css'
import '../src/styles/keeper-v2/verify.css'
import '../src/styles/keeper-v2/registry.css'
import '../src/styles/keeper-v2/monitor.css'
import '../src/styles/keeper-v2/lanes.css'
import '../src/styles/keeper-v2/tempered.css'
import { html } from 'htm/preact'
import { render } from 'preact'
import { ChatTranscript } from '../src/components/chat/primitives'
import { chatHistoryEntriesFromRest } from '../src/keeper-state'

const image = new URL('./failure-output.svg', import.meta.url).href
const audio = new URL('./failure-output.wav', import.meta.url).href
const entries = chatHistoryEntriesFromRest('sangsu', [{
  id: 'failure-output-fixture', role: 'assistant', ts: 1780000001,
  content: 'Keeper request failed: provider disconnected after media',
  kind: 'transport_failure', turn_ref: 'fixture-trace#1',
  delivery_provenance_status: 'valid',
  delivery_provenance: {
    delivery_key: { kind: 'operation', operation_id: 'fixture-operation' },
    transcript_slot: { kind: 'terminal_assistant' },
  },
  blocks: [
    { t: 'image', src: image, cap: '실패 전에 생성된 이미지' },
    { t: 'voice', src: audio, transcript: '실패 전에 생성된 음성', secs: 1 },
  ],
}])
render(html`<${ChatTranscript} entries=${entries} variant="messenger" emptyText="empty" />`, document.getElementById('fixture')!)
