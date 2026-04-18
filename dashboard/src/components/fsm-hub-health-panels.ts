import { html } from 'htm/preact'

import type { KeeperCompositeSnapshot, KeeperCompositeInvariants } from '../api/keeper'

import { invariantRows } from './fsm-hub-invariant-analysis'
import type { InvariantViolationCounts } from './fsm-hub-types'

/** Human-readable descriptions for MeasurementCard auto-rule flags.
    Indexed by rule name -> { on: "this fires next turn", off: "nothing
    pending" } so the tooltip reflects the active half of the flag. */
const MEASUREMENT_FLAG_DESCRIPTIONS: Record<string, { on: string; off: string }> = {
  reflect: {
    on: 'Keeper will pause before the next turn to self-evaluate its recent output (Reflexion loop).',
    off: 'No reflection pending — keeper runs its next turn without self-check.',
  },
  plan: {
    on: 'Keeper will re-plan its remaining steps before executing the next action.',
    off: 'No re-plan scheduled — keeper follows its existing plan.',
  },
  compact: {
    on: 'Context compaction is scheduled — older messages will be summarized to reclaim token budget.',
    off: 'No compaction pending — the context window still has room.',
  },
  handoff: {
    on: 'Keeper will roll over to a new trace/generation while preserving the same keeper identity.',
    off: 'No handoff scheduled — the current generation keeps running on the same trace.',
  },
  guardrail: {
    on: 'A guardrail has tripped — the keeper will halt pending operator intervention.',
    off: 'No guardrail active — keeper runs under its normal safety envelope.',
  },
}

export function MeasurementCard({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const m = snapshot.measurement
  return html`
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] p-3">
      <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)] mb-2">
        Measurement
      </div>
      ${m.captured && m.auto_rules ? html`
        <div class="flex flex-col gap-1.5 text-[11px] text-[var(--text-body)]">
          <div class="flex flex-wrap gap-1.5 font-mono">
            <${Flag} label="reflect" on=${m.auto_rules.reflect} />
            <${Flag} label="plan" on=${m.auto_rules.plan} />
            <${Flag} label="compact" on=${m.auto_rules.compact} />
            <${Flag} label="handoff" on=${m.auto_rules.handoff} />
          </div>
          <div class="flex items-center gap-2 font-mono">
            <${Flag} label="guardrail" on=${m.auto_rules.guardrail_stop} tone="warn" />
            <span
              class="text-[10px] text-[var(--text-dim)] cursor-help"
              title="Goal drift: 0 = keeper is on-target; higher = keeper output is diverging from its declared goal. Values above ~0.5 typically trigger the guardrail."
            >drift ${m.auto_rules.goal_drift.toFixed(2)}</span>
          </div>
          ${m.auto_rules.guardrail_reason ? html`
            <div class="text-[10px] text-[#f59e0b] mt-0.5">사유: ${m.auto_rules.guardrail_reason}</div>
          ` : null}
        </div>
      ` : html`
        <div class="text-[10px] text-[var(--text-dim)]">키퍼가 첫 턴을 완료하면 auto-rules가 여기 표시됩니다</div>
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
  const offCls = 'text-[var(--text-dim)] border-[var(--white-8)]'
  const onCls =
    tone === 'warn'
      ? 'text-[#f59e0b] border-[rgba(251,191,36,0.3)] bg-[rgba(251,191,36,0.08)]'
      : 'text-[#22c55e] border-[rgba(34,197,94,0.3)] bg-[rgba(34,197,94,0.08)]'
  return html`
    <span
      class=${`rounded-sm border px-2 py-0.5 text-[10px] cursor-help ${on ? onCls : offCls}`}
      title=${flagTooltip(label, on)}
    >
      ${label}
    </span>
  `
}

/** Plain-english safety-property descriptions per invariant key. */
const INVARIANT_DESCRIPTIONS: Record<string, string> = {
  phase_turn_alignment:
    'The KSM phase (Running / Compacting / HandingOff / …) must match what the KTC turn lane is doing. A drift means the two state machines disagree on which mode the keeper is in.',
  no_cascade_before_measurement:
    'Cascade selection must not begin before the measurement phase captures auto-rules. A violation usually means a provider call fired without the guardrail/drift checks that gate it.',
  compaction_atomicity:
    'Compaction must be atomic — a turn either sees the old context or the new one, never a half-compacted state. A break corrupts message ordering or duplicates content.',
  event_priority_monotone:
    'Event_bus priorities must be monotone (higher priority delivered first). A break means a critical event was delivered after a lower-priority one, which can skew keeper decisions.',
}

export function invariantDescription(key: string): string {
  return INVARIANT_DESCRIPTIONS[key] ?? 'Invariant defined by the keeper composite contract.'
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
        <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
          Safety
        </div>
        <span
          class=${`rounded-sm border px-2 py-0.5 text-[10px] font-mono tabular-nums ${
            allOk
              ? 'text-[#22c55e] border-[rgba(34,197,94,0.3)] bg-[rgba(34,197,94,0.08)]'
              : 'text-[#ef4444] border-[rgba(239,68,68,0.3)] bg-[rgba(239,68,68,0.08)]'
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
            <li class="flex gap-2 text-[10px] cursor-help" title=${tooltip}>
              <span class=${`mt-[5px] h-1.5 w-1.5 rounded-full shrink-0 ${entry.ok ? 'bg-[#22c55e]' : 'bg-[#ef4444]'}`}></span>
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-1.5">
                  <span class=${entry.ok ? 'text-[var(--text-body)]' : 'text-[#f87171] font-semibold'}>
                    ${entry.label}
                  </span>
                  ${vCount > 0 ? html`
                    <span class="ml-auto text-[8px] font-mono tabular-nums text-[#f87171]">
                      ${vCount}/${sampleCount}
                    </span>
                  ` : null}
                </div>
                <div class="text-[8px] leading-relaxed text-[var(--text-dim)]">
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
