import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { CollapsibleSection } from './common/collapsible'
import {
  MemoryInspector,
  DEFAULT_MEMORY_KEEPERS,
  type MemoryKeeper,
} from './memory-inspector'

interface Props {
  agentName: string
}

function normalizeKeeperName(name: string): string {
  return name.replace(/^keeper-/, '').replace(/-agent$/, '')
}

// Resolve the MemoryInspector keeper from the surfaced agent. When the agent
// matches the inspector's ported roster we reuse the fixture keeper (real ctx /
// status / task counts so the composition math renders); otherwise the keeper
// id alone is enough — the inspector falls back to empty memory for unknown ids
// (memory-inspector.ts getKeeperMemory). ctx 0 / status 'off' keeps an unknown
// keeper's composition bar in the documented "stopped — 활성 컨텍스트 없음" state
// rather than fabricating window usage.
function resolveInspectorKeeper(agentName: string): MemoryKeeper {
  const id = normalizeKeeperName(agentName)
  return (
    DEFAULT_MEMORY_KEEPERS.find(k => k.id === id) ?? {
      id,
      ctx: 0,
      status: 'off',
      tasks: 0,
      traces: 0,
    }
  )
}

export function AgentDetailMemory({ agentName }: Props) {
  const memOpen = useSignal(false)

  return html`
    <${CollapsibleSection} class="v2-monitoring-detail" title="기억" mountWhenOpen=${true}>
      <div class="space-y-4">
        <!-- Memory inspector trigger (rails.jsx:513-515 — ◈ 메모리 보기 · 핀 · 스토어 · 회상) -->
        <button
          type="button"
          class="cmp-open"
          onClick=${() => { memOpen.value = true }}
        >
          ${'◈'} 메모리 보기 <span class="cmp-open-sub">핀 · 스토어 · 회상</span>
        </button>
      </div>
      ${memOpen.value
        ? html`<${MemoryInspector}
            keeper=${resolveInspectorKeeper(agentName)}
            onClose=${() => { memOpen.value = false }}
          />`
        : null}
    <//>
  `
}
