// Harness Health panel — calibration stats, compaction strategy, DNA quality (#3165)

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { get } from '../api/core'
import { lastEvent } from '../sse'
import { Card } from './common/card'

// --- Types ---

interface GateDistribution {
  [gate: string]: number
}

interface CalibrationStats {
  total_verdicts: number
  approve_count: number
  reject_count: number
  gate_distribution: GateDistribution
  labeled_count: number
  false_positive_count: number
  false_negative_count: number
  agreement_rate: number
  fallback_count?: number
  recent_fallback_reasons?: string[]
}

interface HarnessHealthData {
  generated_at: number
  calibration: CalibrationStats
}

// --- Signals ---

const harnessData = signal<HarnessHealthData | null>(null)
const harnessLoading = signal(false)
const harnessError = signal<string | null>(null)

// SSE-driven counters (live updates between API polls)
const recentVerdicts = signal<Array<{ gate: string; verdict: string; ts: number }>>([])

// --- Data loading ---

async function loadHarnessHealth(): Promise<void> {
  if (harnessLoading.value) return
  harnessLoading.value = true
  harnessError.value = null
  try {
    const data = await get<HarnessHealthData>('/api/v1/dashboard/harness-health')
    harnessData.value = data
  } catch (e) {
    harnessError.value = e instanceof Error ? e.message : String(e)
  } finally {
    harnessLoading.value = false
  }
}

// --- SSE handler ---

function handleHarnessSSE(): void {
  const evt = lastEvent.value
  if (!evt) return
  const type = evt.type ?? ''
  if (type === 'oas:masc:harness:verdict_recorded') {
    const p = (evt as unknown as { payload?: Record<string, unknown> }).payload
    if (p) {
      const next = [
        { gate: String(p.gate ?? ''), verdict: String(p.verdict ?? ''), ts: Date.now() },
        ...recentVerdicts.value,
      ].slice(0, 20)
      recentVerdicts.value = next
    }
  }
}

// --- Sub-components ---

function StatCard({ label, value, sub }: { label: string; value: string | number; sub?: string }) {
  return html`
    <div class="bg-[var(--card-bg)] rounded-lg p-3 text-center">
      <div class="text-2xl font-bold text-[color:var(--accent)]">${value}</div>
      <div class="text-xs text-[color:var(--text-muted)] mt-1">${label}</div>
      ${sub ? html`<div class="text-xs text-[color:var(--text-dim)] mt-0.5">${sub}</div>` : null}
    </div>
  `
}

function GateChart({ distribution }: { distribution: GateDistribution }) {
  const entries = Object.entries(distribution).sort((a, b) => b[1] - a[1])
  const max = entries[0]?.[1] ?? 1
  if (entries.length === 0) {
    return html`<div class="text-[color:var(--text-dim)] text-sm">아직 verdict 기록 없음</div>`
  }
  return html`
    <div class="space-y-2">
      ${entries.map(([gate, count]) => html`
        <div class="flex items-center gap-2">
          <span class="text-xs text-[color:var(--text-muted)] w-16 text-right font-mono">${gate}</span>
          <div class="flex-1 bg-[var(--white-6)] rounded h-4 overflow-hidden">
            <div
              class="h-full bg-[var(--accent)]/70 rounded transition-all"
              style=${{ width: `${(count / max) * 100}%` }}
            />
          </div>
          <span class="text-xs text-[color:var(--text-body)] w-8 text-right">${count}</span>
        </div>
      `)}
    </div>
  `
}

function RecentVerdictsFeed() {
  const items = recentVerdicts.value
  if (items.length === 0) return null
  return html`
    <div class="mt-3 space-y-1">
      <div class="text-xs text-[color:var(--text-dim)] uppercase tracking-wider mb-1">Live Feed</div>
      ${items.slice(0, 8).map(v => html`
        <div class="flex items-center gap-2 text-xs">
          <span class=${`inline-block w-2 h-2 rounded-full ${
            v.verdict === 'approve' ? 'bg-green-500' : 'bg-red-500'
          }`} />
          <span class="font-mono text-[color:var(--text-muted)]">${v.gate}</span>
          <span class="text-[color:var(--text-dim)]">${v.verdict}</span>
        </div>
      `)}
    </div>
  `
}

// --- Main Component ---

export function HarnessHealth() {
  useEffect(() => { void loadHarnessHealth() }, [])
  useEffect(handleHarnessSSE, [lastEvent.value])

  const cal = harnessData.value?.calibration
  const rejectRate = cal && cal.total_verdicts > 0
    ? ((cal.reject_count / cal.total_verdicts) * 100).toFixed(1)
    : '0'
  const agreementPct = cal ? (cal.agreement_rate * 100).toFixed(1) : '-'

  // Detect evaluator degradation: fallback > 80% of total verdicts
  const fallbackCount = cal?.fallback_count ?? 0
  const isFallbackDominant = cal != null && cal.total_verdicts > 0
    && (fallbackCount / cal.total_verdicts) > 0.8
  const fallbackReasons = cal?.recent_fallback_reasons ?? []

  return html`
    <div class="space-y-4">
      <${Card} title="Evaluator 캘리브레이션" class="section">
        ${harnessLoading.value ? html`
          <div class="text-[color:var(--text-dim)] text-sm">로딩 중...</div>
        ` : harnessError.value ? html`
          <div class="text-red-400 text-sm">${harnessError.value}</div>
        ` : !cal ? html`
          <div class="text-[color:var(--text-dim)] text-sm">데이터 없음</div>
        ` : html`
          ${isFallbackDominant ? html`
            <div class="mb-4 rounded-lg border border-yellow-500/30 bg-yellow-500/10 px-4 py-3">
              <div class="text-yellow-400 text-sm font-medium mb-1">Evaluator 미연결</div>
              <div class="text-yellow-400/80 text-xs">
                전체 ${cal.total_verdicts}건 중 ${fallbackCount}건이 fallback으로 처리됨.
                LLM evaluator cascade가 동작하지 않아 모든 verdict가 자동 승인 상태입니다.
              </div>
              ${fallbackReasons.length > 0 ? html`
                <details class="mt-2">
                  <summary class="text-yellow-400/60 text-xs cursor-pointer">최근 에러 (${fallbackReasons.length}건)</summary>
                  <div class="mt-1 space-y-1">
                    ${fallbackReasons.map(r => html`
                      <div class="text-xs text-yellow-400/50 font-mono break-all">${r}</div>
                    `)}
                  </div>
                </details>
              ` : null}
            </div>
          ` : null}

          <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
            <${StatCard} label="총 Verdict" value=${cal.total_verdicts} />
            <${StatCard} label="Reject 비율" value="${rejectRate}%" />
            <${StatCard} label="인간 라벨" value=${cal.labeled_count} />
            <${StatCard}
              label="일치율"
              value="${agreementPct}%"
              sub="FP:${cal.false_positive_count} FN:${cal.false_negative_count}"
            />
          </div>

          <div class="text-xs text-[color:var(--text-dim)] uppercase tracking-wider mb-2">Gate별 분포</div>
          <${GateChart} distribution=${cal.gate_distribution} />
          <${RecentVerdictsFeed} />

          <button
            class="mt-3 text-xs text-[color:var(--text-dim)] hover:text-[color:var(--accent)] transition-colors"
            onClick=${() => void loadHarnessHealth()}
          >새로고침</button>
        `}
      <//>
    </div>
  `
}
