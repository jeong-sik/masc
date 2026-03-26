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
    <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3 text-center">
      <div class="text-2xl font-bold text-[var(--accent)]">${value}</div>
      <div class="mt-1 text-xs text-[var(--text-muted)]">${label}</div>
      ${sub ? html`<div class="mt-0.5 text-xs text-[var(--text-dim)]">${sub}</div>` : null}
    </div>
  `
}

function GateChart({ distribution }: { distribution: GateDistribution }) {
  const entries = Object.entries(distribution).sort((a, b) => b[1] - a[1])
  const max = entries[0]?.[1] ?? 1
  if (entries.length === 0) {
    return html`<div class="text-sm text-[var(--text-dim)]">아직 verdict 기록 없음</div>`
  }
  return html`
    <div class="space-y-2">
      ${entries.map(([gate, count]) => html`
        <div class="flex items-center gap-2">
          <span class="w-16 text-right font-mono text-xs text-[var(--text-muted)]">${gate}</span>
          <div class="h-4 flex-1 overflow-hidden rounded bg-[var(--white-6)]">
            <div
              class="h-full rounded opacity-80 transition-all"
              style=${{ width: `${(count / max) * 100}%`, background: 'var(--accent)' }}
            />
          </div>
          <span class="w-8 text-right text-xs text-[var(--text-body)]">${count}</span>
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
      <div class="mb-1 text-xs uppercase tracking-wider text-[var(--text-dim)]">Live Feed</div>
      ${items.slice(0, 8).map(v => html`
        <div class="flex items-center gap-2 text-xs">
          <span class=${`inline-block w-2 h-2 rounded-full ${
            v.verdict === 'approve' ? 'bg-[var(--ok)]' : 'bg-[var(--bad)]'
          }`} />
          <span class="font-mono text-[var(--text-muted)]">${v.gate}</span>
          <span class="text-[var(--text-dim)]">${v.verdict}</span>
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
          <div class="text-sm text-[var(--text-dim)]">로딩 중...</div>
        ` : harnessError.value ? html`
          <div class="text-sm text-[var(--bad)]">${harnessError.value}</div>
        ` : !cal ? html`
          <div class="text-sm text-[var(--text-dim)]">데이터 없음</div>
        ` : html`
          ${isFallbackDominant ? html`
            <div class="mb-4 rounded-lg border border-[var(--warn-30)] bg-[var(--warn-12)] px-4 py-3">
              <div class="mb-1 text-sm font-medium text-[var(--warn)]">Evaluator 미연결</div>
              <div class="text-xs text-[var(--warn)]">
                전체 ${cal.total_verdicts}건 중 ${fallbackCount}건이 fallback으로 처리됨.
                LLM evaluator cascade가 동작하지 않아 모든 verdict가 자동 승인 상태입니다.
              </div>
              ${fallbackReasons.length > 0 ? html`
                <details class="mt-2">
                  <summary class="cursor-pointer text-xs text-[var(--warn)] opacity-70">최근 에러 (${fallbackReasons.length}건)</summary>
                  <div class="mt-1 space-y-1">
                    ${fallbackReasons.map(r => html`
                      <div class="break-all font-mono text-xs text-[var(--warn)] opacity-70">${r}</div>
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

          <div class="mb-2 text-xs uppercase tracking-wider text-[var(--text-dim)]">Gate별 분포</div>
          <${GateChart} distribution=${cal.gate_distribution} />
          <${RecentVerdictsFeed} />

          <button
            class="mt-3 text-xs text-[var(--text-muted)] transition-colors hover:text-[var(--accent)]"
            onClick=${() => void loadHarnessHealth()}
          >새로고침</button>
        `}
      <//>
    </div>
  `
}
