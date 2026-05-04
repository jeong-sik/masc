// ProviderCapabilityMatrix — Feature × Provider matrix, OAS wiring gaps,
// cascade routing traces, and anti-pattern registry. Static data from
// sec02/sec03/sec04/sec05 analysis with live provider overlay from
// /api/v1/providers.
//
// Sub-views (via FilterChips):
//   providers    — OAS provider kind definitions (sec02 Table 1)
//   matrix       — 15 features × 13 providers
//   cascade      — OAS cascade routing trace scenarios (sec03)
//   benchmarks   — BFCL V3/V4 rankings
//   wiring       — OAS wiring mismatches vs official API
//   roadmap     — P0–P7 improvement priorities (sec06 Table 6-1/6-2)
//   models      — Per-provider model catalog with pricing/context
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
import { CascadeTrace } from './cascade-trace'
import { WiringGaps } from './wiring-gaps'
import { AntiPatternList } from './anti-patterns'
import { OasProviderTable } from './oas-provider-table'
import { Roadmap } from './roadmap'
import { ModelCatalog } from './model-catalog'

type CapView = 'providers' | 'matrix' | 'models' | 'cascade' | 'benchmarks' | 'wiring' | 'roadmap' | 'anti-patterns'

const CAP_VIEWS: Array<{ key: CapView; label: string }> = [
  { key: 'providers', label: 'OAS 프로바이더' },
  { key: 'matrix', label: '기능 매트릭스' },
  { key: 'models', label: '모델 카탈로그' },
  { key: 'cascade', label: '캐스케이드 트레이스' },
  { key: 'benchmarks', label: 'BFCL 벤치마크' },
  { key: 'wiring', label: 'OAS 배선 갭' },
  { key: 'roadmap', label: '개선 로드맵' },
  { key: 'anti-patterns', label: '안티패턴' },
]

const PROVIDER_REFRESH_MS = 30_000

export function ProviderCapabilityMatrix() {
  const activeView = useSignal<CapView>('matrix')
  const liveProviders = useSignal<DashboardRuntimeProviderSnapshot[]>([])
  const updatedLabel = useSignal<string | null>(null)

  useEffect(() => {
    let disposed = false
    let inFlight: AbortController | null = null

    const refresh = () => {
      inFlight?.abort()
      const ctrl = new AbortController()
      inFlight = ctrl
      void fetchRuntimeProviders({ signal: ctrl.signal })
        .then(res => {
          if (disposed || ctrl.signal.aborted) return
          liveProviders.value = res.providers
          updatedLabel.value = res.updated_at ?? null
        })
        .catch(err => {
          if (err instanceof DOMException && err.name === 'AbortError') return
          console.warn('[capability-matrix] provider fetch failed', err instanceof Error ? err.message : err)
        })
    }

    refresh()
    const timer = window.setInterval(refresh, PROVIDER_REFRESH_MS)
    return () => {
      disposed = true
      window.clearInterval(timer)
      inFlight?.abort()
    }
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
          <span class="t-caption">
            프로바이더 상태: ${updatedAt}
          </span>
        ` : null}
      </div>

      ${activeView.value === 'providers' ? html`
        <${Card}>
          <h3 class="t-title mb-2">OAS Provider Capability 정의</h3>
          <p class="t-meta mb-3">
            sec02 Table 1 — 12개 런타임 provider kind의 capability flag와 한계값.
            CLI wrapper 3종은 <code class="t-code">usage: strip</code>으로 토큰 카운트를 노출하지 않음.
          </p>
          <${OasProviderTable} />
        <//>
      ` : activeView.value === 'matrix' ? html`
        <div class="flex flex-col gap-2">
          <${MatrixLegend} />
          <${FeatureMatrix} liveProviders=${liveProviders.value} />
        </div>
      ` : activeView.value === 'models' ? html`
        <${Card}>
          <h3 class="text-sm font-semibold text-[var(--color-fg-primary)] mb-2">Provider 모델 카탈로그</h3>
          <p class="t-meta mb-3">
            Provider별 공식 모델 목록, 가격($/1M tokens), Context 한계, CLI transport 구현 비교.
            GLM Coding Plan은 Claude Code 호환 엔드포인트를 통한 별도 모델 매핑 사용.
          </p>
          <${ModelCatalog} />
        <//>
      ` : activeView.value === 'cascade' ? html`
        <${Card}>
          <h3 class="text-sm font-semibold text-[var(--color-fg-primary)] mb-2">OAS Cascade 라우팅 트레이스</h3>
          <p class="t-meta mb-3">
            sec03 분석 — Provider cascade 경로의 4가지 대표 시나리오.
            Rate-limit/Timeout → Cooldown 게이트 → 다음 Provider 순차 시도.
            Exhaustion 시 turn 실패로 보고.
          </p>
          <${CascadeTrace} />
        <//>
      ` : activeView.value === 'benchmarks' ? html`
        <${Card}>
          <h3 class="text-sm font-semibold text-[var(--color-fg-primary)] mb-2">BFCL Function Calling 순위</h3>
          <p class="t-meta mb-3">
            sec04 Table 4.2.2 — 2026년 4월 기준 BFCL V3/V4 성능 순위.
            GLM-4.5(70.85%)과 Claude 계열(70%대)이 스키마 준수에서 상위.
          </p>
          <${BfclRankings} />
        <//>
      ` : activeView.value === 'wiring' ? html`
        <${Card}>
          <h3 class="text-sm font-semibold text-[var(--color-fg-primary)] mb-2">OAS 배선 vs 공식 API 지원</h3>
          <p class="t-meta mb-3">
            OAS가 선언한 capability와 실제 프로바이더 API 동작 사이의 불일치.
            High 영향도 항목은 tool calling 비활성화로 이어져 OAS 라우팅 정확도에 직접 영향.
          </p>
          <${WiringGaps} />
        <//>
      ` : activeView.value === 'roadmap' ? html`
        <${Card}>
          <h3 class="text-sm font-semibold text-[var(--color-fg-primary)] mb-2">P0–P7 개선 로드맵</h3>
          <p class="t-meta mb-3">
            sec06 종합 개선 계획 — 비결정론적 구현 경계를 결정론적으로 전환하는 8개 우선순위.
            P0(Verification Loop)이 기반 인프라로 다른 모든 개선의 토대.
          </p>
          <${Roadmap} />
        <//>
      ` : activeView.value === 'anti-patterns' ? html`
        <${Card}>
          <h3 class="text-sm font-semibold text-[var(--color-fg-primary)] mb-2">안티패턴 레지스트리</h3>
          <p class="t-meta mb-3">
            sec05 분석에서 식별된 32개 안티패턴. Silent Failure가 운영 가시성에 가장 큰 위협.
          </p>
          <${AntiPatternList} />
        <//>
      ` : null}
    </div>
  `
}
