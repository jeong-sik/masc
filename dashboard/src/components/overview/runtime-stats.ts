import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchRuntimeModelMetrics, type DashboardRuntimeModelMetricsResponse } from '../../api/dashboard-runtime'
import { setupVisibleAutoRefresh, DEFAULT_PANEL_REFRESH_MS } from '../../lib/auto-refresh'
import { RouteLink } from '../common/route-link'

type State = { kind: 'loading' } | { kind: 'error'; message: string }
  | { kind: 'ready' | 'pending'; value: DashboardRuntimeModelMetricsResponse; receivedAt: Date }

function number(value: number | null | undefined, unit = ''): string {
  return value != null && Number.isFinite(value) && value >= 0
    ? `${value.toLocaleString(undefined, { maximumFractionDigits: 1 })}${unit}` : '미보고'
}

export function OverviewRuntimeStats() {
  const [windowMinutes, setWindowMinutes] = useState(60)
  const [generation, setGeneration] = useState(0)
  const [state, setState] = useState<State>({ kind: 'loading' })
  useEffect(() => {
    const controller = new AbortController()
    let inFlight = false
    setState({ kind: 'loading' })
    const refresh = async () => {
      if (controller.signal.aborted || inFlight) return
      inFlight = true
      try {
        const value = await fetchRuntimeModelMetrics(windowMinutes, 0, { signal: controller.signal })
        if (!controller.signal.aborted) setState({
          kind: value.cost_ledger_read?.state === 'pending' ? 'pending' : 'ready',
          value, receivedAt: new Date(),
        })
      } catch (error) {
        if (!controller.signal.aborted) setState({ kind: 'error', message: error instanceof Error ? error.message : String(error) })
      } finally { inFlight = false }
    }
    void refresh()
    const stopRefresh = setupVisibleAutoRefresh(refresh, DEFAULT_PANEL_REFRESH_MS)
    return () => { stopRefresh(); controller.abort() }
  }, [windowMinutes, generation])
  const data = state.kind === 'ready' || state.kind === 'pending' ? state.value : null
  const ledger = data?.cost_ledger_read
  return html`<section class="ov-card min-w-0" aria-label="런타임 사용 통계" data-overview-runtime-stats>
    <div class="flex flex-wrap items-center justify-between gap-3">
      <h2>런타임 사용 통계</h2>
      <div class="flex flex-wrap items-center gap-3">
        <label>집계 요청 기간 <select value=${windowMinutes} onChange=${(event: Event) => setWindowMinutes(Number((event.target as HTMLSelectElement).value))}>
          <option value="30">30분</option><option value="60">1시간</option><option value="360">6시간</option><option value="1440">24시간</option>
        </select></label>
        <button type="button" onClick=${() => setGeneration(value => value + 1)}>통계 새로 읽기</button>
        <${RouteLink} tab="monitoring" params=${{ section: 'runtime', view: 'cost' }} class="underline">토큰·지연 상세</${RouteLink}>
      </div>
    </div>
    <p class="text-sm text-text-muted">Keeper 결정 기록과 날짜별 비용 원장을 결합한 런타임별 집계입니다. 토큰·지연은 오류 없는 기록 중 보고된 값만 포함하며, 작업 완료율을 뜻하지 않습니다.</p>
    ${state.kind === 'loading' ? html`<p role="status">런타임 통계를 읽고 있습니다.</p>` : null}
    ${state.kind === 'error' ? html`<p role="alert">통계를 읽지 못했습니다: ${state.message}</p>` : null}
    ${data ? html`
      <p class="text-sm">서버 집계 창: ${data.window_minutes == null ? '미보고' : `${number(data.window_minutes)}분`} · 응답 수신 ${state.kind === 'ready' || state.kind === 'pending' ? state.receivedAt.toLocaleString() : ''}</p>
      <p class="text-xs text-text-muted">집계 기준 시각과 결정 기록의 보존·읽기 누락은 API가 제공하지 않습니다. 선택한 기간 전체가 관측되었다는 의미는 아닙니다.</p>
      ${ledger?.state === 'pending' ? html`<p role="status">서버가 첫 집계를 준비하고 있습니다. 표시 중에는 자동으로 다시 읽습니다.</p>`
        : ledger?.state === 'unavailable' ? html`<p role="alert">비용 원장을 읽지 못했습니다: ${ledger.detail ?? '상세 미보고'}. 아래 값은 읽을 수 있었던 결정 기록 기반입니다.</p>`
        : ledger?.state === 'available' ? html`<p class="text-xs">비용 원장 읽기 완료 · 형식 오류 ${number(ledger.malformed_rows)} · 스키마 위반 ${number(ledger.schema_violation_rows)} · 식별 충돌 ${number(ledger.identity_conflict_rows)}행</p>`
          : html`<p class="text-xs">비용 원장 읽기 상태 미보고</p>`}
      ${state.kind === 'pending' ? null : data.models.length === 0 ? html`<p role="status">${ledger ? '반환된 집계에 런타임 기록이 없습니다.' : '아직 관측할 런타임 집계가 반환되지 않았습니다. 초기 캐시 응답이거나 해당 기간의 기록이 없을 수 있습니다.'}</p>`
        : html`<div class="max-w-full overflow-x-auto" tabIndex=${0} role="region" aria-label="런타임별 토큰·지연·결과">
          <table class="w-full text-sm"><thead><tr class="border-b border-border">
            <th scope="col" class="p-2 text-left">런타임</th><th scope="col" class="p-2 text-left">기록 결과</th>
            <th scope="col" class="p-2 text-left">보고된 토큰</th><th scope="col" class="p-2 text-left">보고된 지연</th>
            <th scope="col" class="p-2 text-left">관측 누락</th>
          </tr></thead><tbody>${data.models.map(row => html`<tr key=${row.model_id} class="border-b border-border align-top">
            <th scope="row" class="p-2 text-left break-all">${row.model_id}</th>
            <td class="p-2 whitespace-nowrap">오류 없음 ${number(row.success_count)}<br />오류 ${number(row.error_count)}</td>
            <td class="p-2 whitespace-nowrap">입력 ${number(row.total_input_tokens)}<br />출력 ${number(row.total_output_tokens)}</td>
            <td class="p-2 whitespace-nowrap">p50 ${number(row.p50_latency_ms, ' ms')}<br />p95 ${number(row.p95_latency_ms, ' ms')}</td>
            <td class="p-2">사용량 보고 ${number(row.usage_sample_count)} · 누락 ${number(row.usage_missing_count)}<br />텔레메트리 보고 ${number(row.telemetry_sample_count)} · 누락 ${number(row.telemetry_missing_count)}
              ${row.primary_coverage_reason ? html`<p class="break-words">사유: ${row.primary_coverage_reason}</p>` : null}
            </td>
          </tr>`)}</tbody></table>
        </div>`}
    ` : null}
  </section>`
}
