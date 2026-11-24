import { html } from 'htm/preact'
import { formatDuration } from '../lib/format-time'
import { nowSecondsSignal, useNowSecondsTicker } from '../lib/now-signal'
import { CADENCE_WINDOW_HOURS, cadenceWindow, type CadenceWindow } from '../lib/keeper-turn-pulse'
import type { Keeper } from '../types'

const CAUSE_LABELS: ReadonlyArray<readonly [keyof Pick<CadenceWindow, 'scheduled' | 'reacted' | 'chat' | 'own' | 'unknown'>, string]> = [
  ['scheduled', '예약'],
  ['reacted', '반응'],
  ['chat', '채팅'],
  ['own', '스스로'],
  ['unknown', '모름'],
]

const chipClass = 'inline-flex items-center gap-1.5 text-2xs text-[var(--color-fg-muted)] px-2.5 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]'

function CadenceChip({ window, nowSeconds }: { window: CadenceWindow; nowSeconds: number }) {
  const rate = window.knownFrom === null
    ? html`시간당 <span class="font-mono text-[var(--color-fg-primary)]">${(window.turns / window.hours).toFixed(1)}</span>`
    : html`기록 시작 ${formatDuration(Math.max(0, nowSeconds - window.knownFrom))} 전`
  return html`
    <span class=${chipClass} title="최근 ${window.hours}시간에 끝난 턴과 깨운 이유">
      최근 ${window.hours}시간 <span class="font-mono font-medium text-[var(--color-fg-primary)]">${window.turns}</span>턴 · ${rate}
      <span class="text-[var(--color-fg-subtle)]">
        (${CAUSE_LABELS.map(([key, label], i) => html`${i > 0 ? ' · ' : ''}${label} ${window[key]}`)})
      </span>
    </span>
  `
}

/** How often the keeper worked lately and what started each turn. Draws
 *  nothing while the server has sent no pulse for the keeper. */
export function KeeperCadence({ keeper }: { keeper: Keeper }) {
  useNowSecondsTicker()
  const nowSeconds = nowSecondsSignal.value
  const reading = keeper.recent_turns
  if (reading === undefined || reading.state === 'absent') return null
  if (reading.state === 'invalid') {
    return html`<div class="px-1 text-2xs text-[var(--color-fg-muted)]">주기: ${reading.reason}</div>`
  }
  return html`
    <div class="flex flex-wrap items-start gap-3 px-1 v2-monitoring-row">
      ${CADENCE_WINDOW_HOURS.map(hours => html`
        <${CadenceChip} key=${hours} window=${cadenceWindow(reading.pulse, nowSeconds, hours)} nowSeconds=${nowSeconds} />
      `)}
    </div>
  `
}
