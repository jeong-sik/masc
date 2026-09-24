import { html } from 'htm/preact'
import { useMemo, useState } from 'preact/hooks'
import type { RuntimeResolution } from '../api/schemas/runtime-resolved'
import type { StandaloneLaneSnapshotRow } from '../api/dashboard-standalone-lanes'
import type { RuntimeExactSlotAction, RuntimeExactSlotDirection } from '../api/dashboard-runtime'
import { getRuntimeTomlKey } from '../lib/runtime-toml-config'
import { ActionButton } from './common/button'

export function RuntimeExactLaneEditor({ sourceText, lanes, runtimes, slotsDisabled, deadlineDisabled,
  onSlotAction, onDeadlineChange }: {
  sourceText: string
  lanes: readonly StandaloneLaneSnapshotRow[]
  runtimes: readonly RuntimeResolution[]
  slotsDisabled: boolean
  deadlineDisabled: boolean
  onSlotAction: (laneId: string, action: RuntimeExactSlotAction, runtimeId: string,
    direction?: RuntimeExactSlotDirection) => void
  onDeadlineChange: (providerId: string, seconds: number | null) => void
}) {
  const [newSlot, setNewSlot] = useState<Record<string, string>>({})
  const orderedLanes = useMemo(() => [...lanes].sort((left, right) => {
    if (left.laneId === 'librarian_exact') return -1
    if (right.laneId === 'librarian_exact') return 1
    return left.laneId.localeCompare(right.laneId)
  }), [lanes])
  const runtimeById = new Map(runtimes.map(runtime => [runtime.id, runtime]))

  return html`<div class="space-y-4" data-testid="runtime-exact-lane-editor">
    <p class="text-xs text-[var(--color-fg-secondary)]">
      Exact-output Lane은 HTTP slots를 위에서 아래로 시도한 뒤 CLI slots를 시도합니다.
      후보 변경은 서버 routing API가 즉시 기록하고, 후보 종류와 허용 여부도 서버가 판정합니다.
      HTTP 본문 deadline 변경은 이 페이지의 저장 버튼으로 기록되며 서버 재시작 후 적용됩니다.
    </p>
    ${slotsDisabled && !deadlineDisabled ? html`<p role="status" class="text-xs">현재 편집 중인 설정을 저장한 뒤 후보를 변경하세요.</p>` : null}
    ${orderedLanes.map(lane => {
      const declared = [...lane.declaredSlots, ...lane.declaredCliSlots]
      const available = runtimes.filter(runtime => !declared.includes(runtime.id))
      const selected = newSlot[lane.laneId] ?? ''
      const groups = [
        { kind: 'slots', label: 'HTTP slots · 먼저 시도', slots: lane.declaredSlots },
        { kind: 'cli_slots', label: 'CLI slots · HTTP 소진 후', slots: lane.declaredCliSlots },
      ]
      return html`<section key=${lane.laneId} class="rounded border border-[var(--color-border-default)] p-3 space-y-3"
        data-testid=${`exact-lane-${lane.laneId}`}>
        <header class="flex flex-wrap items-baseline justify-between gap-2">
          <h2 class="font-semibold">${lane.laneId === 'librarian_exact' ? 'Librarian' : lane.label}</h2>
          <code class="text-2xs">runtime.exact_output_lanes.${lane.laneId}</code>
        </header>
        ${lane.admissionError ? html`<p role="alert">${lane.admissionError}</p>` : null}
        ${groups.map(group => html`<div key=${group.kind} class="space-y-1">
          <h3 class="text-xs font-semibold">${group.label}</h3>
          ${group.slots.length === 0 ? html`<p class="text-xs text-[var(--color-fg-muted)]">후보 없음</p>` : null}
          ${group.slots.map((slot, index) => {
            const providerId = runtimeById.get(slot)?.provider
            const bodyDeadline = group.kind === 'slots' && providerId
              ? getRuntimeTomlKey(sourceText, `providers.${providerId}`, 'exact-body-timeout-s')
              : undefined
            return html`<div key=${slot} class="rounded border border-[var(--color-border-subtle)] p-2 text-xs">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-mono">${index + 1}. ${slot}</span>
                ${lane.droppedSlots.includes(slot) ? html`<span role="status">admission 거절</span>` : null}
                <${ActionButton} variant="ghost" size="sm" ariaLabel=${`${slot} 위로`}
                  disabled=${slotsDisabled || index === 0}
                  onClick=${() => onSlotAction(lane.laneId, 'move', slot, 'up')}>↑</${ActionButton}>
                <${ActionButton} variant="ghost" size="sm" ariaLabel=${`${slot} 아래로`}
                  disabled=${slotsDisabled || index === group.slots.length - 1}
                  onClick=${() => onSlotAction(lane.laneId, 'move', slot, 'down')}>↓</${ActionButton}>
                <${ActionButton} variant="ghost" size="sm" ariaLabel=${`${slot} 제거`}
                  disabled=${slotsDisabled}
                  onClick=${() => onSlotAction(lane.laneId, 'drop', slot)}>제거</${ActionButton}>
              </div>
              ${group.kind === 'slots' && providerId ? html`<label class="mt-1 flex flex-wrap items-center gap-2">
                <span>HTTP 본문 deadline (초)</span>
                <input type="number" min="0.001" step="any" class="rt-input-sm mono"
                  aria-label=${`${providerId} exact-body-timeout-s`}
                  value=${bodyDeadline ?? ''} placeholder="미설정"
                  disabled=${deadlineDisabled}
                  onChange=${(event: Event) => {
                    const raw = (event.currentTarget as HTMLInputElement).value
                    const seconds = raw === '' ? null : Number(raw)
                    if (seconds === null || Number.isFinite(seconds) && seconds > 0) onDeadlineChange(providerId, seconds)
                  }} />
                ${bodyDeadline === undefined ? html`<span role="alert" class="text-[var(--color-status-error)]">
                  provider 설정에 없음: 기본 Exact target은 missing_deadline으로 거절됩니다.
                  catalog 대체 target은 자체 deadline을 확인하세요. 저장한 값은 서버 재시작 후 적용됩니다.
                </span>` : null}
              </label>` : null}
              ${group.kind === 'slots' && !providerId ? html`<p role="status">이 후보는 현재 runtime catalogue에 없어 provider deadline을 편집할 수 없습니다.</p>` : null}
            </div>`
          })}
        </div>`)}
        <div class="flex flex-wrap gap-2">
          <select aria-label=${`${lane.laneId} 추가할 runtime`} class="rt-select" value=${selected}
            disabled=${slotsDisabled} onChange=${(event: Event) =>
              setNewSlot(current => ({ ...current, [lane.laneId]: (event.currentTarget as HTMLSelectElement).value }))}>
            <option value="">후보 선택</option>
            ${available.map(runtime => html`<option key=${runtime.id} value=${runtime.id}>${runtime.id}</option>`)}
          </select>
          <${ActionButton} variant="ghost" size="sm" ariaLabel=${`${lane.laneId} 후보 추가`}
            disabled=${slotsDisabled || selected === ''}
            onClick=${() => {
              if (!selected) return
              onSlotAction(lane.laneId, 'append', selected)
              setNewSlot(current => ({ ...current, [lane.laneId]: '' }))
            }}>후보 추가</${ActionButton}>
        </div>
      </section>`
    })}
  </div>`
}
