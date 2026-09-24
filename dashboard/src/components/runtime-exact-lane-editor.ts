import { html } from 'htm/preact'
import { useMemo, useState } from 'preact/hooks'
import {
  enabledRuntimeIds, getRuntimeTomlKey, parseRuntimeTomlEnvironment,
  parseRuntimeTomlExactLanes,
} from '../lib/runtime-toml-config'
import { ActionButton } from './common/button'

type SlotKind = 'slots' | 'cli_slots'

export function RuntimeExactLaneEditor({ sourceText, disabled, onSlotsChange, onDeadlineChange }: {
  sourceText: string
  disabled: boolean
  onSlotsChange: (laneId: string, kind: SlotKind, slots: string[]) => void
  onDeadlineChange: (providerId: string, seconds: number | null) => void
}) {
  const [newSlot, setNewSlot] = useState<Record<string, string>>({})
  const lanes = useMemo(() => parseRuntimeTomlExactLanes(sourceText).sort((left, right) => {
    if (left.id === 'librarian_exact') return -1
    if (right.id === 'librarian_exact') return 1
    return left.id.localeCompare(right.id)
  }), [sourceText])
  const environment = useMemo(() => parseRuntimeTomlEnvironment(sourceText), [sourceText])
  const providers = new Map(environment.providers.map(provider => [provider.id, provider]))
  const runtimes = enabledRuntimeIds(environment)
  const isCli = (runtimeId: string) => {
    const provider = providers.get(runtimeId.split('.')[0] ?? '')
    return provider?.protocol === 'codex-app-server' || provider?.protocol === 'claude-code'
      || provider?.protocol === 'antigravity-cli'
  }
  const move = (slots: string[], index: number, by: number) => {
    const next = [...slots]
    const other = index + by
    if (other < 0 || other >= next.length) return next
    ;[next[index], next[other]] = [next[other]!, next[index]!]
    return next
  }

  return html`<div class="space-y-4" data-testid="runtime-exact-lane-editor">
    <p class="text-xs text-[var(--color-fg-secondary)]">
      Exact-output Lane은 HTTP slots를 위에서 아래로 시도한 뒤 CLI slots를 시도합니다.
      후보 변경은 이 페이지의 저장 버튼으로 runtime.toml에 기록됩니다.
      HTTP 본문 deadline 변경은 실행 중인 Exact target에 즉시 반영되지 않으며 서버 재시작 후 적용됩니다.
    </p>
    ${lanes.map(lane => {
      const declared = [...lane.slots, ...lane.cliSlots]
      const available = runtimes.filter(id => !declared.includes(id)
        && (lane.id !== 'workspace_curator_exact' || !isCli(id)))
      const selected = newSlot[lane.id] ?? ''
      const groups: { kind: SlotKind; label: string; slots: string[] }[] = [
        { kind: 'slots', label: 'HTTP slots · 먼저 시도', slots: lane.slots },
        { kind: 'cli_slots', label: 'CLI slots · HTTP 소진 후', slots: lane.cliSlots },
      ]
      return html`<section key=${lane.id} class="rounded border border-[var(--color-border-default)] p-3 space-y-3"
        data-testid=${`exact-lane-${lane.id}`}>
        <header class="flex flex-wrap items-baseline justify-between gap-2">
          <h2 class="font-semibold">${lane.id === 'librarian_exact' ? 'Librarian' : lane.id}</h2>
          <code class="text-2xs">runtime.exact_output_lanes.${lane.id}</code>
        </header>
        ${lane.error ? html`<p role="alert">일부 후보 배열을 읽지 못했습니다: ${lane.error}. 후보 변경은 TOML 원문에서 하세요. 읽힌 HTTP 후보의 provider deadline은 아래에서 편집할 수 있습니다.</p>` : null}
        ${groups.map(group => html`<div key=${group.kind} class="space-y-1">
          <h3 class="text-xs font-semibold">${group.label}</h3>
          ${group.slots.length === 0 ? html`<p class="text-xs text-[var(--color-fg-muted)]">후보 없음</p>` : null}
          ${group.slots.map((slot, index) => {
            const providerId = slot.split('.')[0] ?? ''
            const bodyDeadline = group.kind === 'slots'
              ? getRuntimeTomlKey(sourceText, `providers.${providerId}`, 'exact-body-timeout-s')
              : undefined
            return html`<div key=${slot} class="rounded border border-[var(--color-border-subtle)] p-2 text-xs">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-mono">${index + 1}. ${slot}</span>
                <${ActionButton} variant="ghost" size="sm" ariaLabel=${`${slot} 위로`} disabled=${disabled || lane.error !== null || index === 0}
                  onClick=${() => onSlotsChange(lane.id, group.kind, move(group.slots, index, -1))}>↑</${ActionButton}>
                <${ActionButton} variant="ghost" size="sm" ariaLabel=${`${slot} 아래로`} disabled=${disabled || lane.error !== null || index === group.slots.length - 1}
                  onClick=${() => onSlotsChange(lane.id, group.kind, move(group.slots, index, 1))}>↓</${ActionButton}>
                <${ActionButton} variant="ghost" size="sm" ariaLabel=${`${slot} 제거`} disabled=${disabled || lane.error !== null || declared.length === 1}
                  onClick=${() => onSlotsChange(lane.id, group.kind, group.slots.filter((_, at) => at !== index))}>제거</${ActionButton}>
              </div>
              ${group.kind === 'slots' ? html`<label class="mt-1 flex flex-wrap items-center gap-2">
                <span>HTTP 본문 deadline (초)</span>
                <input type="number" min="0.001" step="any" class="rt-input-sm mono"
                  aria-label=${`${providerId} exact-body-timeout-s`}
                  value=${bodyDeadline ?? ''} placeholder="미설정"
                  disabled=${disabled}
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
            </div>`
          })}
        </div>`)}
        <div class="flex flex-wrap gap-2">
          <select aria-label=${`${lane.id} 추가할 runtime`} class="rt-select" value=${selected}
            disabled=${disabled || lane.error !== null} onChange=${(event: Event) =>
              setNewSlot(current => ({ ...current, [lane.id]: (event.currentTarget as HTMLSelectElement).value }))}>
            <option value="">후보 선택</option>
            ${available.map(id => html`<option key=${id} value=${id}>${id} · ${isCli(id) ? 'CLI' : 'HTTP'}</option>`)}
          </select>
          <${ActionButton} variant="ghost" size="sm" disabled=${disabled || lane.error !== null || selected === ''}
            onClick=${() => {
              if (!selected) return
              const kind = isCli(selected) ? 'cli_slots' : 'slots'
              onSlotsChange(lane.id, kind, [...(kind === 'cli_slots' ? lane.cliSlots : lane.slots), selected])
              setNewSlot(current => ({ ...current, [lane.id]: '' }))
            }}>후보 추가</${ActionButton}>
        </div>
      </section>`
    })}
  </div>`
}
