import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchKeeperMetrics, type KeeperMetricsWindow } from '../api/keeper-metrics'
import type { Keeper } from '../types'
import { ContextChart, MetricsCharts, TokenTrendChart } from './keeper-detail-charts'
import { CtxCompositionPanel } from './keeper-detail-ctx-composition'
import { InferenceTelemetryPanel, PromptTelemetryPanel } from './keeper-detail-telemetry'

type MetricsState =
  | { readonly kind: 'loading'; readonly keeper: string }
  | { readonly kind: 'error'; readonly keeper: string; readonly message: string }
  | { readonly kind: 'ready'; readonly keeper: string; readonly window: KeeperMetricsWindow; readonly fetchedAt: number }

/** The fleet summary has no series: hydrate one selected Keeper on demand. */
export function KeeperMetricsPanel({ keeper }: { keeper: Keeper }) {
  const [revision, setRevision] = useState(0)
  const [state, setState] = useState<MetricsState>({ kind: 'loading', keeper: keeper.name })
  useEffect(() => {
    const controller = new AbortController()
    setState({ kind: 'loading', keeper: keeper.name })
    void fetchKeeperMetrics(keeper.name, { signal: controller.signal }).then(window => {
      if (!controller.signal.aborted) setState({ kind: 'ready', keeper: keeper.name, window, fetchedAt: Date.now() })
    }).catch((error: unknown) => {
      if (!controller.signal.aborted) setState({
        kind: 'error', keeper: keeper.name,
        message: error instanceof Error ? error.message : '관측 기록 읽기 실패',
      })
    })
    return () => controller.abort()
  }, [keeper.name, revision])

  // Identity is checked during render as well as at the request boundary.
  const current = state.keeper === keeper.name ? state : { kind: 'loading' as const }
  const busy = current.kind === 'loading'
  return html`
    <section class="space-y-4" aria-label="Keeper 실행 관측" aria-busy=${busy}>
      <div class="flex flex-wrap items-center justify-between gap-2 text-xs text-[var(--color-fg-secondary)]">
        <span>선택 Keeper의 저장된 실행 기록</span>
        <button type="button" disabled=${busy} onClick=${() => setRevision(value => value + 1)}>관측 기록 새로고침</button>
      </div>
      ${current.kind === 'loading' ? html`<p role="status">관측 기록을 읽고 있습니다.</p>` : null}
      ${current.kind === 'error' ? html`<p role="alert">관측 기록 읽기 실패: ${current.message}</p>` : null}
      ${current.kind === 'ready' ? (() => {
        const window = current.window
        const observedKeeper = { ...keeper, metrics_series: window.series }
        return html`
          <p class="text-xs text-[var(--color-fg-secondary)] tabular-nums">
            ${new Date(current.fetchedAt).toLocaleString()}에 읽음 · 최근 최대 ${window.limit}개 저장 행 중 ${window.scannedRows}개 확인
            · 실행 ${window.series.length}개 · 손상·해석 불가 ${window.skippedRows}개 · 자동 갱신 없음
          </p>
          ${window.series.length === 0 ? html`<p role="status">이 범위에 표시할 실행 관측값이 없습니다.</p>` : html`
            ${window.series.length >= 2 ? html`<${ContextChart} keeper=${observedKeeper} />` : null}
            <${MetricsCharts} keeper=${observedKeeper} />
            <${TokenTrendChart} keeper=${observedKeeper} />
            <${CtxCompositionPanel} keeper=${observedKeeper} />
            <${PromptTelemetryPanel} keeper=${observedKeeper} />
            <${InferenceTelemetryPanel} keeper=${observedKeeper} />
          `}
        `
      })() : null}
    </section>
  `
}
