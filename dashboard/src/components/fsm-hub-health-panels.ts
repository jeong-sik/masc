import { html } from 'htm/preact'

import type { KeeperCompositeSnapshot, KeeperCompositeInvariants } from '../api/keeper'

import { invariantRows } from './fsm-hub-invariant-analysis'
import type { InvariantViolationCounts } from './fsm-hub-types'

/** Human-readable descriptions for MeasurementCard auto-rule flags.
    Indexed by rule name -> { on: "this fires next turn", off: "nothing
    pending" } so the tooltip reflects the active half of the flag. */
const MEASUREMENT_FLAG_DESCRIPTIONS: Record<string, { on: string; off: string }> = {
  reflect: {
    on: '키퍼가 다음 턴 전에 일시 정지하고 최근 출력을 자기 평가합니다 (Reflexion loop).',
    off: '예약된 reflection 없음 — 키퍼는 self-check 없이 다음 턴을 실행합니다.',
  },
  plan: {
    on: '키퍼가 다음 행동 실행 전에 남은 단계를 재계획합니다.',
    off: '예약된 재계획 없음 — 키퍼는 기존 계획을 따릅니다.',
  },
  compact: {
    on: '컨텍스트 압축 예약됨 — 오래된 메시지를 요약해 토큰 예산을 회수합니다.',
    off: '예약된 압축 없음 — 컨텍스트 윈도우에 여유가 있습니다.',
  },
  handoff: {
    on: '키퍼가 동일 정체성을 유지하며 새 trace/generation 으로 이관됩니다.',
    off: '예약된 handoff 없음 — 현재 generation 이 같은 trace 에서 계속 실행됩니다.',
  },
  guardrail: {
    on: 'guardrail 발동됨 — 키퍼가 운영자 개입 대기 상태로 멈춥니다.',
    off: '활성 guardrail 없음 — 키퍼가 일반 safety envelope 안에서 실행됩니다.',
  },
}

export function MeasurementCard({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const m = snapshot.measurement
  return html`
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] p-3">
      <div class="text-3xs font-semibold uppercase tracking-1 text-[var(--color-fg-muted)] mb-2">
        측정
      </div>
      ${m.captured && m.auto_rules ? html`
        <div class="flex flex-col gap-1.5 text-2xs text-[var(--color-fg-primary)]">
          <div class="flex flex-wrap gap-1.5 font-mono">
            <${Flag} label="reflect" on=${m.auto_rules.reflect} />
            <${Flag} label="plan" on=${m.auto_rules.plan} />
            <${Flag} label="compact" on=${m.auto_rules.compact} />
            <${Flag} label="handoff" on=${m.auto_rules.handoff} />
          </div>
          <div class="flex items-center gap-2 font-mono">
            <${Flag} label="guardrail" on=${m.auto_rules.guardrail_stop} tone="warn" />
            <span
              class="text-3xs text-[var(--color-fg-disabled)] cursor-help"
              title="Goal drift: 0 = 키퍼가 목표와 정렬됨; 높을수록 키퍼 출력이 선언된 goal 에서 벗어남. 약 0.5 이상이면 보통 guardrail 발동."
            >drift ${m.auto_rules.goal_drift.toFixed(2)}</span>
          </div>
          ${m.auto_rules.guardrail_reason ? html`
            <div class="text-3xs text-[var(--amber-bright)] mt-0.5">사유: ${m.auto_rules.guardrail_reason}</div>
          ` : null}
        </div>
      ` : html`
        <div class="text-3xs text-[var(--color-fg-disabled)]">키퍼가 첫 턴을 완료하면 auto-rules가 여기 표시됩니다</div>
      `}
    </div>
  `
}

export function flagTooltip(label: string, on: boolean): string {
  const desc = MEASUREMENT_FLAG_DESCRIPTIONS[label]
  if (!desc) return `${label}: ${on ? 'active' : 'inactive'}`
  return `${label} (${on ? 'active' : 'inactive'})\n${on ? desc.on : desc.off}`
}

function Flag({ label, on, tone = 'ok' }: { label: string; on: boolean; tone?: 'ok' | 'warn' }) {
  const offCls = 'text-[var(--color-fg-disabled)] border-[var(--white-8)]'
  const onCls =
    tone === 'warn'
      ? 'text-[var(--amber-bright)] border-[rgba(251,191,36,0.3)] bg-[var(--warn-8)]'
      : 'text-[var(--emerald)] border-[var(--emerald-30)] bg-[var(--emerald-8)]'
  return html`
    <span
      class=${`rounded-sm border px-2 py-0.5 text-3xs cursor-help ${on ? onCls : offCls}`}
      title=${flagTooltip(label, on)}
    >
      ${label}
    </span>
  `
}

/** Plain-english safety-property descriptions per invariant key. */
const INVARIANT_DESCRIPTIONS: Record<string, string> = {
  phase_turn_alignment:
    'KSM phase (Running / Compacting / HandingOff / …) 와 KTC turn lane 이 일치해야 함. drift 가 발생하면 두 state machine 이 keeper mode 에 대해 의견 불일치.',
  no_cascade_before_measurement:
    'Cascade selection 은 measurement phase 가 auto-rule 을 capture 하기 전에 시작되면 안 됨. violation 은 보통 guardrail/drift check 없이 provider call 이 발사된 경우.',
  compaction_atomicity:
    'Compaction 은 atomic 해야 함 — turn 이 old context 또는 new context 만 보고 half-compacted state 는 안 봄. break 시 message ordering 손상 또는 content 중복.',
  event_priority_monotone:
    'Event_bus priority 는 monotone 해야 함 (higher priority 먼저 delivered). break 시 critical event 가 lower priority 뒤에 도착해 keeper decision 왜곡.',
}

export function invariantDescription(key: string): string {
  return INVARIANT_DESCRIPTIONS[key] ?? 'keeper composite contract 가 정의한 invariant.'
}

export function InvariantsPanel({
  snapshot,
  violationCounts,
  sampleCount,
}: {
  snapshot: KeeperCompositeSnapshot
  violationCounts: InvariantViolationCounts
  sampleCount: number
}) {
  const entries = invariantRows(snapshot)
  const okCount = entries.filter(entry => entry.ok).length
  const total = entries.length
  const allOk = okCount === total
  const badgeText = allOk ? `${total}/${total}` : `${okCount}/${total}`
  return html`
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] p-3">
      <div class="flex items-center justify-between mb-2">
        <div class="text-3xs font-semibold uppercase tracking-1 text-[var(--color-fg-muted)]">
          Safety
        </div>
        <span
          class=${`rounded-sm border px-2 py-0.5 text-3xs font-mono tabular-nums ${
            allOk
              ? 'text-[var(--emerald)] border-[var(--emerald-30)] bg-[var(--emerald-8)]'
              : 'text-[var(--color-status-err)] border-[rgba(239,68,68,0.3)] bg-[rgba(239,68,68,0.08)]'
          }`}
          title=${allOk
            ? `All ${total} keeper composite invariants hold.`
            : `${total - okCount} of ${total} invariants are currently violated.`}
        >
          ${badgeText}
        </span>
      </div>
      <ul class="flex flex-col gap-1">
        ${entries.map(entry => {
          const desc = invariantDescription(entry.key)
          const vCount = violationCounts[entry.key as keyof KeeperCompositeInvariants] ?? 0
          const rate = sampleCount > 0
            ? `${vCount}/${sampleCount} 위반`
            : ''
          const tooltip = `${entry.label} — ${entry.ok ? 'holds' : 'BROKEN'}\n${desc}${rate ? `\n누적: ${rate}` : ''}`
          return html`
            <li class="flex gap-2 text-3xs cursor-help" title=${tooltip}>
              <span class=${`mt-[5px] h-1.5 w-1.5 rounded-full shrink-0 ${entry.ok ? 'bg-[var(--emerald)]' : 'bg-[var(--color-status-err)]'}`}></span>
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-1.5">
                  <span class=${entry.ok ? 'text-[var(--color-fg-primary)]' : 'text-[var(--bad-light)] font-semibold'}>
                    ${entry.label}
                  </span>
                  ${vCount > 0 ? html`
                    <span class="ml-auto text-3xs font-mono tabular-nums text-[var(--bad-light)]">
                      ${vCount}/${sampleCount}
                    </span>
                  ` : null}
                </div>
                <div class="text-3xs leading-relaxed text-[var(--color-fg-disabled)]">
                  ${entry.detail}
                </div>
              </div>
            </li>
          `
        })}
      </ul>
    </div>
  `
}
