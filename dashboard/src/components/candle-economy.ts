import { html } from 'htm/preact'
import { candleAmountText, type CandleReading } from '../api/schemas/candle-observation'

export function CandleSummary({ reading }: { reading: CandleReading }) {
  if (reading.status === 'off') return null
  return html`<section class="ov-card p-4" aria-label="Candle" data-testid="candle-summary">
    <h3 class="m-0 mb-2 text-sm">Candle</h3>
    ${reading.status === 'ready'
      ? html`<dl class="m-0 flex flex-wrap gap-x-8 gap-y-2 text-sm">
          ${([['발행', reading.issued_milli], ['소각', reading.burned_milli], ['유통', reading.circulating_milli]] as const).map(([label, amount]) => html`
            <div class="min-w-0"><dt class="text-text-secondary">${label}</dt><dd class="m-0 font-mono break-all">${candleAmountText(amount)} Candle</dd></div>`)}
        </dl>`
      : html`<p class="m-0 text-sm" data-testid="candle-unavailable">${reading.status === 'disabled' ? '사용 중지' : '조회 불가'} · ${reading.reason}</p>`}
  </section>`
}

export function KeeperCandleBalance({ reading, amount }: { reading: CandleReading; amount: string | null | undefined }) {
  if (reading.status === 'off') return null
  const value = reading.status === 'ready'
    ? typeof amount === 'string' ? `${candleAmountText(amount)} Candle` : '조회 불가'
    : `${reading.status === 'disabled' ? '사용 중지' : '조회 불가'} · ${reading.reason}`
  return html`<span class="text-xs break-all" data-testid="keeper-candle-balance">잔액 ${value}</span>`
}
