// Quotas tab panel for runtimes that a refused credential, a live rate limit,
// or a failed last attempt affects. Wording follows the TUI Runtime screen
// ("Cred refused", "Rate limit" with a countdown, the failure name).

import { html } from 'htm/preact'
import { formatRelativeSec } from '../../lib/format-time'
import { causeBadgeStyle, formatLocalReleaseTime, formatReleaseSummary } from './quota-rest-groups'
import {
  attemptFailureLabel,
  collectRuntimeLiveness,
  type RuntimeLivenessBlock,
  type RuntimeLivenessRow,
} from './runtime-liveness'
import type { RuntimeResolution } from './types'

const PILL_STYLE = {
  padding: '1px var(--sp-2)',
  borderRadius: 'var(--radius-pill)',
  fontWeight: 600,
  whiteSpace: 'nowrap',
} as const

function blockText(block: RuntimeLivenessBlock, nowUnix: number): { label: string; tone: 'warn' | 'bad'; when: string } {
  switch (block.kind) {
    case 'credential_refused': {
      const local = formatLocalReleaseTime(block.since, nowUnix)
      return {
        label: '인증 거부',
        tone: 'bad',
        when: `${formatRelativeSec(nowUnix - block.since)}부터${local ? ` (${local})` : ''}`,
      }
    }
    case 'rate_limited': {
      if (block.resetsAt === null) {
        return { label: '속도 제한 (429)', tone: 'warn', when: '해제 시각 없음 · 응답이 오면 해제' }
      }
      const rel = formatReleaseSummary(block.resetsAt, true, nowUnix)
      return { label: '속도 제한 (429)', tone: 'warn', when: `${rel.countdown}${rel.localTime ? ` (${rel.localTime})` : ''}` }
    }
  }
}

function LivenessRow({ row, nowUnix }: { row: RuntimeLivenessRow; nowUnix: number }) {
  const { runtime, block, failedAttempt } = row
  const blocked = block === null ? null : blockText(block, nowUnix)
  return html`
    <div
      data-testid=${`runtime-liveness-${runtime.id}`}
      style=${{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: 'var(--sp-2)',
        flexWrap: 'wrap',
        padding: 'var(--sp-1) var(--sp-2)',
        borderRadius: 'var(--radius-sm)',
        background: 'var(--bg-1)',
        border: '1px solid var(--line-1)',
      }}
    >
      <span style=${{ display: 'inline-flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap', minWidth: 0 }}>
        <span style=${{ fontWeight: 600, fontSize: 'var(--fs-12)' }}>${runtime.model || runtime.id}</span>
        <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>${runtime.id}</span>
      </span>
      <span class="mono tnum" style=${{ display: 'inline-flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap', fontSize: 'var(--fs-11)' }}>
        ${blocked && html`
          <span style=${{ ...causeBadgeStyle(blocked.tone), ...PILL_STYLE }}>${blocked.label}</span>
          <span style=${{ color: 'var(--fg-2)' }}>${blocked.when}</span>
        `}
        ${failedAttempt && html`
          <span style=${{ color: 'var(--warn-fg)' }}>
            마지막 실패 ${attemptFailureLabel(failedAttempt.failure)} · ${failedAttempt.recorded_by} · ${formatRelativeSec(nowUnix - failedAttempt.noted_at)}
          </span>
        `}
      </span>
    </div>
  `
}

export function RuntimeLivenessPanel({ runtimes }: { runtimes: readonly RuntimeResolution[] }) {
  const nowUnix = Date.now() / 1000
  const rows = collectRuntimeLiveness(runtimes, nowUnix)
  if (rows.length === 0) return null
  const anyRefused = rows.some((row) => row.block?.kind === 'credential_refused')
  return html`
    <section
      class="wka-card"
      data-testid="runtime-liveness-panel"
      aria-label="호출이 막히거나 실패한 런타임"
      style=${{
        display: 'flex',
        flexDirection: 'column',
        gap: 'var(--sp-2)',
        borderColor: anyRefused ? 'var(--err-border)' : 'var(--warn-border)',
        background: anyRefused ? 'var(--err-soft)' : 'var(--warn-soft)',
      }}
    >
      <span style=${{ fontSize: 'var(--fs-13)', fontWeight: 600 }}>호출이 막히거나 실패한 런타임 (${rows.length})</span>
      <p style=${{ margin: 0, fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>
        인증 거부와 속도 제한 중인 런타임은 가용에서 뺍니다. 마지막 실패는 그 런타임이 다시 응답하면 사라집니다.
      </p>
      <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
        ${rows.map((row) => html`<${LivenessRow} key=${row.runtime.id} row=${row} nowUnix=${nowUnix} />`)}
      </div>
    </section>
  `
}
