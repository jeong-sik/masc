import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { formatPct, formatTokens } from '../lib/format-number'
import { TextInput } from './common/input'
import type { Keeper } from '../types'

const fieldSearch = signal('')

// ── Raw Data Debug Panel ─────────────────────────────────

export function RawDataDebug({ keeper }: { keeper: Keeper }) {
  const filter = fieldSearch.value.toLowerCase()

  const fields: { title: string; key: string; value: string }[] = [
    { title: '이름', key: 'name', value: keeper.name },
    { title: '이모지', key: 'emoji', value: keeper.emoji ?? '-' },
    { title: '한글명', key: 'koreanName', value: keeper.koreanName ?? '-' },
    { title: '상태', key: 'status', value: keeper.status },
    { title: '주력', key: 'primaryValue', value: keeper.primaryValue ?? '-' },
    { title: '세대', key: 'generation', value: String(keeper.generation ?? '-') },
    { title: '턴', key: 'turn_count', value: String(keeper.turn_count ?? '-') },
    { title: '컨텍스트', key: 'context_ratio', value: formatPct(keeper.context_ratio) },
    { title: '하트비트', key: 'last_heartbeat', value: keeper.last_heartbeat ?? '-' },
    { title: '특성', key: 'traits', value: keeper.traits?.join(', ') || '-' },
    { title: '관심사', key: 'interests', value: keeper.interests?.join(', ') || '-' },
  ]

  // Extra fields from keeper object
  const extras: { title: string; value: string; mono?: boolean }[] = []
  if (keeper.trace_id) extras.push({ title: '추적 ID', value: keeper.trace_id, mono: true })
  if (keeper.agent_name) extras.push({ title: '에이전트', value: keeper.agent_name })
  if (keeper.context_source) extras.push({ title: '컨텍스트 소스', value: keeper.context_source })
  if (keeper.context_tokens != null) extras.push({ title: '컨텍스트 토큰', value: formatTokens(keeper.context_tokens) })
  if (keeper.context_max != null) extras.push({ title: '컨텍스트 최대', value: formatTokens(keeper.context_max) })
  if (keeper.memory_recent_note) extras.push({ title: '메모리 노트', value: keeper.memory_recent_note })
  if (keeper.k2k_count != null) extras.push({ title: 'K2K 카운트', value: String(keeper.k2k_count) })
  if (keeper.conversation_tail_count != null) extras.push({ title: '대화 tail', value: String(keeper.conversation_tail_count) })
  if (keeper.handoff_count_total != null) extras.push({ title: '핸드오프 총합', value: String(keeper.handoff_count_total) })
  if (keeper.compaction_count != null) extras.push({ title: '압축 횟수', value: String(keeper.compaction_count) })
  if (keeper.last_compaction_saved_tokens != null) extras.push({ title: '마지막 압축 절약', value: formatTokens(keeper.last_compaction_saved_tokens) })
  if (keeper.context?.message_count != null) extras.push({ title: '메시지 수', value: String(keeper.context.message_count) })
  if (keeper.context?.has_checkpoint != null) extras.push({ title: '체크포인트 보유', value: keeper.context.has_checkpoint ? '예' : '아니오' })

  const filtered = filter
    ? fields.filter(f => f.title.toLowerCase().includes(filter) || f.key.includes(filter) || f.value.toLowerCase().includes(filter))
    : fields

  return html`
    <div class="max-h-[460px] overflow-y-auto v2-monitoring-panel">
      <${TextInput}
        placeholder="필드 검색..."
        value=${fieldSearch.value}
        onInput=${(e: Event) => { fieldSearch.value = (e.target as HTMLInputElement).value }}
      />
      <div class="flex flex-col v2-monitoring-row">
        ${filtered.map((f, i) => html`
          <div class="grid grid-cols-[100px_80px_1fr] gap-2 py-2 px-2 text-xs rounded-[var(--r-1)] ${i % 2 === 0 ? 'bg-[var(--color-bg-surface)]' : ''} v2-monitoring-row">
            <span class="font-semibold text-[var(--color-fg-primary)] truncate">${f.title}</span>
            <span class="font-mono text-[var(--cyan)] text-2xs truncate">${f.key}</span>
            <span class="text-right text-[var(--color-fg-primary)] truncate">${f.value}</span>
          </div>
        `)}
        ${extras.map((f, i) => html`
          <div class="grid grid-cols-[100px_1fr] gap-2 py-2 px-2 text-xs rounded-[var(--r-1)] ${(filtered.length + i) % 2 === 0 ? 'bg-[var(--color-bg-surface)]' : ''} v2-monitoring-row">
            <span class="font-semibold text-[var(--color-fg-primary)] truncate">${f.title}</span>
            <span class="text-right text-[var(--color-fg-primary)] truncate ${f.mono ? 'font-mono' : ''}">${f.value}</span>
          </div>
        `)}
      </div>
    </div>
  `
}
