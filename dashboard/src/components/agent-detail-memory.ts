import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { CollapsibleSection } from './common/collapsible'
import {
  MemoryInspector,
  type MemoryKeeper,
} from './memory-inspector'
import type { Keeper } from '../types'
import { keeperBucket } from './keeper-workspace/keeper-workspace-shared'

interface Props {
  agentName: string
  keeper?: Keeper | null
}

function normalizeKeeperName(name: string): string {
  return name.replace(/^keeper-/, '').replace(/-agent$/, '')
}

function resolveInspectorKeeper(agentName: string, keeper?: Keeper | null): MemoryKeeper {
  const id = normalizeKeeperName(agentName)
  if (!keeper) return { id, status: 'unknown' }
  const bucket = keeperBucket(keeper)
  const status =
    bucket === 'running' || bucket === 'stuck'
      ? 'run'
      : bucket === 'paused'
        ? 'pause'
        : 'off'
  return { id: keeper.name, status }
}

export function AgentDetailMemory({ agentName, keeper }: Props) {
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
            keeper=${resolveInspectorKeeper(agentName, keeper)}
            onClose=${() => { memOpen.value = false }}
          />`
        : null}
    <//>
  `
}
