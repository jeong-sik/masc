// ProviderCapabilityMatrix — Feature × Provider matrix, OAS wiring gaps,
// and anti-pattern registry. Static data from sec02/sec04/sec05 analysis
// with live provider overlay from /api/v1/providers.
//
// Sub-views (via FilterChips):
//   providers    — OAS provider kind definitions (sec02 Table 1)
//   matrix       — 15 features × 13 providers
//   benchmarks   — BFCL V3/V4 rankings
//   wiring       — OAS wiring mismatches vs official API
//   anti-patterns — 32 anti-patterns (S/F/M/H categories)

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { Card } from '../common/card'
import { FilterChips } from '../common/filter-chips'
import {
  fetchRuntimeProviders,
  type DashboardRuntimeProviderSnapshot,
} from '../../api/dashboard'
import { FeatureMatrix, MatrixLegend } from './feature-matrix'
import { BfclRankings } from './bfcl-rankings'
import { WiringGaps } from './wiring-gaps'
import { AntiPatternList } from './anti-patterns'
import { OasProviderTable } from './oas-provider-table'

type CapView = 'providers' | 'matrix' | 'benchmarks' | 'wiring' | 'anti-patterns'

const CAP_VIEWS: Array<{ key: CapView; label: string }> = [
  { key: 'providers', label: 'OAS 프로바이더' },
  { key: 'matrix', label: '기능 매트릭스' },
  { key: 'benchmarks', label: 'BFCL 벤치마크' },
  { key: 'wiring', label: 'OAS 배선 갭' },
  { key: 'anti-patterns', label: '안티패턴' },
]

export function ProviderCapabilityMatrix() {
  const activeView = useSignal<CapView>('matrix')
  const liveProviders = useSignal<DashboardRuntimeProviderSnapshot[]>([])
  const updatedLabel = useSignal<string | null>(null)

  useEffect(() => {
    const ctrl = new AbortController()
    void fetchRuntimeProviders({ signal: ctrl.signal })
      .then(res => {
        liveProviders.value = res.providers
        updatedLabel.value = res.updated_at ?? null
      })
      .catch(err => {
        if (err instanceof DOMException && err.name === 'AbortError') return
        console.warn('[capability-matrix] provider fetch failed', err instanceof Error ? err.message : err)
      })
    return () => { ctrl.abort() }
  }, [])

  const updatedAt = updatedLabel.value

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center justify-between gap-3 flex-wrap">
        <${FilterChips}
          chips=${CAP_VIEWS}
          value=${activeView.value}
          onChange=${(v: CapView) => { activeView.value = v }}
        />
        ${updatedAt ? html`
          <span class="text-[10px] font-mono text-[var(--color-fg-muted)]">
            프로바이더 상태: ${updatedAt}
          </span>
        ` : null}
      </div>

      ${activeView.value === 'providers' ? html`
        <${Card}>
          <h3 class="text-sm font-semibold text-[var(--color-fg-primary)] mb-2">OAS Provider Capability 정의</h3>
          <p class="text-xs text-[var(--color-fg-muted)] mb-3">
            sec02 Table 1 — 12개 런타임 provider kind의 capability flag와 한계값.
            CLI wrapper 3종은 <code class="font-mono text-[10px] bg-[var(--white-4)] px-1 rounded">usage: strip</code>으로 토큰 카운트를 노출하지 않음.
          </p>
          <${OasProviderTable} />
        <//>
      ` : activeView.value === 'matrix' ? html`
        <div class="flex flex-col gap-2">
          <${MatrixLegend} />
          <${FeatureMatrix} liveProviders=${liveProviders.value} />
        </div>
      ` : activeView.value === 'benchmarks' ? html`
        <${Card}>
          <h3 class="text-sm font-semibold text-[var(--color-fg-primary)] mb-2">BFCL Function Calling 순위</h3>
          <p class="text-xs text-[var(--color-fg-muted)] mb-3">
            sec04 Table 4.2.2 — 2026년 4월 기준 BFCL V3/V4 성능 순위.
            GLM-4.5(70.85%)과 Claude 계열(70%대)이 스키마 준수에서 상위.
          </p>
          <${BfclRankings} />
        <//>
      ` : activeView.value === 'wiring' ? html`
        <${Card}>
          <h3 class="text-sm font-semibold text-[var(--color-fg-primary)] mb-2">OAS 배선 vs 공식 API 지원</h3>
          <p class="text-xs text-[var(--color-fg-muted)] mb-3">
            OAS가 선언한 capability와 실제 프로바이더 API 동작 사이의 불일치.
            High 영향도 항목은 tool calling 비활성화로 이어져 OAS 라우팅 정확도에 직접 영향.
          </p>
          <${WiringGaps} />
        <//>
      ` : activeView.value === 'anti-patterns' ? html`
        <${Card}>
          <h3 class="text-sm font-semibold text-[var(--color-fg-primary)] mb-2">안티패턴 레지스트리</h3>
          <p class="text-xs text-[var(--color-fg-muted)] mb-3">
            sec05 분석에서 식별된 32개 안티패턴. Silent Failure가 운영 가시성에 가장 큰 위협.
          </p>
          <${AntiPatternList} />
        <//>
      ` : null}
    </div>
  `
}
