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
    <div class="bg-slate-800 rounded-lg p-3 text-center">
      <div class="text-2xl font-bold text-amber-400">${value}</div>
      <div class="text-xs text-slate-400 mt-1">${label}</div>
      ${sub ? html`<div class="text-xs text-slate-500 mt-0.5">${sub}</div>` : null}
    </div>
  `
}

function GateChart({ distribution }: { distribution: GateDistribution }) {
  const entries = Object.entries(distribution).sort((a, b) => b[1] - a[1])
  const max = entries[0]?.[1] ?? 1
  if (entries.length === 0) {
    return html`<div class="text-slate-500 text-sm">아직 verdict 기록 없음</div>`
  }
  return html`
    <div class="space-y-2">
      ${entries.map(([gate, count]) => html`
        <div class="flex items-center gap-2">
          <span class="text-xs text-slate-400 w-16 text-right font-mono">${gate}</span>
          <div class="flex-1 bg-slate-700 rounded h-4 overflow-hidden">
            <div
              class="h-full bg-amber-500/70 rounded transition-all"
              style=${{ width: `${(count / max) * 100}%` }}
            />
          </div>
          <span class="text-xs text-slate-300 w-8 text-right">${count}</span>
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
      <div class="text-xs text-slate-500 uppercase tracking-wider mb-1">Live Feed</div>
      ${items.slice(0, 8).map(v => html`
        <div class="flex items-center gap-2 text-xs">
          <span class=${`inline-block w-2 h-2 rounded-full ${
            v.verdict === 'approve' ? 'bg-green-500' : 'bg-red-500'
          }`} />
          <span class="font-mono text-slate-400">${v.gate}</span>
          <span class="text-slate-500">${v.verdict}</span>
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

  return html`
    <div class="space-y-4">
      <${Card} title="Evaluator 캘리브레이션" class="section">
        ${harnessLoading.value ? html`
          <div class="text-slate-500 text-sm">로딩 중...</div>
        ` : harnessError.value ? html`
          <div class="text-red-400 text-sm">${harnessError.value}</div>
        ` : !cal ? html`
          <div class="text-slate-500 text-sm">데이터 없음</div>
        ` : html`
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

          <div class="text-xs text-slate-500 uppercase tracking-wider mb-2">Gate별 분포</div>
          <${GateChart} distribution=${cal.gate_distribution} />
          <${RecentVerdictsFeed} />

          <button
            class="mt-3 text-xs text-slate-500 hover:text-amber-400 transition-colors"
            onClick=${() => void loadHarnessHealth()}
          >새로고침</button>
        `}
      <//>
    </div>
  `
}
