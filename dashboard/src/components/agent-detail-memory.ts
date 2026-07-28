import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { LoadingState } from './common/feedback-state'
import { ProgressBar } from './common/progress-bar'
import { CollapsibleSection } from './common/collapsible'
import {
  fetchMemorySubsystems,
  type MemorySubsystemsResponse,
  type MemorySubsystemsSynapse,
} from '../api/dashboard'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
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

function matchesKeeper(synapseAgent: string, keeperName: string): boolean {
  const a = normalizeKeeperName(synapseAgent)
  const b = normalizeKeeperName(keeperName)
  return a === b
}

function synapseWeightFillClass(weight: number): string {
  if (weight >= 0.7) return 'bg-[var(--ok-10)]'
  if (weight >= 0.4) return 'bg-[var(--warn-10)]'
  return 'bg-[var(--bad-10)]'
}

function SynapseWeightBar({ weight }: { weight: number }) {
  const pct = Math.round(weight * 100)
  return html`
    <${ProgressBar}
      pct=${pct}
      size="sm"
      trackClass="w-16 rounded-[var(--r-1)]"
      class=${synapseWeightFillClass(weight)}
      ariaLabel="시냅스 가중치 ${pct}%"
    />
  `
}

export function AgentDetailMemory({ agentName }: Props) {
  const resource = useManagedAsyncResource<MemorySubsystemsResponse>(null)
  const memOpen = useSignal(false)

  useEffect(() => {
    // `limit` has no effect here — Hebbian synapses are unpaginated on the
    // backend (compute_hebbian takes no limit) and this component filters
    // client-side to the agent's own edges via `matchesKeeper`.
    void resource.load(async (signal) => fetchMemorySubsystems({ signal }))
    return () => resource.cancel()
  }, [agentName, resource])

  const { loading, error, data } = resource.state.value
  if (loading) return html`<${LoadingState}>메모리 컨텍스트 로드 중...<//>`
  if (error)
    return html`<div class="text-sm text-[var(--color-status-warn)]" role="alert">메모리 로드 실패: ${error}</div>`
  if (!data) return html`<${LoadingState}>메모리 컨텍스트 로드 중...<//>`

  // Filter hebbian synapses where this keeper is either endpoint
  const allSynapses = data.hebbian?.synapses ?? []
  const myEdges = allSynapses.filter(
    (s: MemorySubsystemsSynapse) =>
      matchesKeeper(s.from_agent, agentName) ||
      matchesKeeper(s.to_agent, agentName),
  )
  const outgoing = myEdges.filter((s: MemorySubsystemsSynapse) =>
    matchesKeeper(s.from_agent, agentName),
  )
  const incoming = myEdges.filter(
    (s: MemorySubsystemsSynapse) => matchesKeeper(s.to_agent, agentName),
  )

  return html`
    <${CollapsibleSection} class="v2-monitoring-detail" title="협업 & 기억" mountWhenOpen=${true}>
      <div class="space-y-4">
        <!-- Memory inspector trigger (rails.jsx:513-515 — ◈ 메모리 보기 · 핀 · 스토어 · 회상) -->
        <button
          type="button"
          class="cmp-open"
          onClick=${() => { memOpen.value = true }}
        >
          ${'◈'} 메모리 보기 <span class="cmp-open-sub">핀 · 스토어 · 회상</span>
        </button>

        <!-- Hebbian collaboration -->
        <div>
          <div class="text-xs text-[var(--color-fg-disabled)] uppercase tracking-wide mb-2">
            협업 시냅스 (나에게 연결된 ${myEdges.length}개)
          </div>
          ${
            myEdges.length === 0
              ? html`<div class="text-sm text-[var(--color-fg-disabled)]">
                  아직 협업 데이터가 없습니다. task 완료 시 자동 학습됩니다.
                </div>`
              : html`
                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                    ${outgoing.length > 0
                      ? html`
                          <div>
                            <div class="text-2xs text-[var(--color-fg-muted)] mb-1">
                              내가 강화한 파트너 (out, ${outgoing.length})
                            </div>
                            <div class="space-y-1">
                              ${outgoing.map(
                                (s: MemorySubsystemsSynapse) => html`
                                  <div class="v2-monitoring-row flex items-center gap-2 text-xs">
                                    <span class="font-mono flex-1 truncate">${normalizeKeeperName(s.to_agent)}</span>
                                    <${SynapseWeightBar} weight=${s.weight} />
                                    <span class="text-[var(--color-fg-muted)] w-10 text-right">${Math.round(s.weight * 100)}%</span>
                                  </div>
                                `,
                              )}
                            </div>
                          </div>
                        `
                      : null}
                    ${incoming.length > 0
                      ? html`
                          <div>
                            <div class="text-2xs text-[var(--color-fg-muted)] mb-1">
                              나를 강화한 파트너 (in, ${incoming.length})
                            </div>
                            <div class="space-y-1">
                              ${incoming.map(
                                (s: MemorySubsystemsSynapse) => html`
                                  <div class="v2-monitoring-row flex items-center gap-2 text-xs">
                                    <span class="font-mono flex-1 truncate">${normalizeKeeperName(s.from_agent)}</span>
                                    <${SynapseWeightBar} weight=${s.weight} />
                                    <span class="text-[var(--color-fg-muted)] w-10 text-right">${Math.round(s.weight * 100)}%</span>
                                  </div>
                                `,
                              )}
                            </div>
                          </div>
                        `
                      : null}
                  </div>
                `
          }
        </div>
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
