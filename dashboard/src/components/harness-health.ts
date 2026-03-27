// Safety Harness panel — evaluator calibration and long-running runtime rails.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { get } from '../api/core'
import { lastEvent } from '../sse'
import { Card } from './common/card'

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

interface HarnessVerdictItem {
  timestamp: number
  task_id: string
  task_title: string
  agent_name: string
  gate: string
  verdict: string
  evaluator_cascade: string
  fallback_reason?: string | null
}

interface PreCompactEvent {
  timestamp: number
  keeper_name: string
  context_ratio: number
  message_count: number
  token_count: number
  strategies: string[]
  model_family: string
  trigger: string
}

interface DnaQualityDimensions {
  has_goal_anchor?: boolean
  has_task_anchor?: boolean
  has_recent_context?: boolean
  truncation_artifacts?: number
  content_length?: number
}

interface DnaQualityEvent {
  timestamp: number
  keeper_name: string
  score: number
  dimensions: DnaQualityDimensions
}

interface HarnessSignalSection<T> {
  description: string
  recent_events: T[]
  total_recent: number
}

interface HarnessHealthData {
  generated_at: number
  scope_note: string
  calibration: CalibrationStats
  recent_verdicts: HarnessVerdictItem[]
  pre_compact: HarnessSignalSection<PreCompactEvent>
  dna_quality: HarnessSignalSection<DnaQualityEvent>
}

const harnessData = signal<HarnessHealthData | null>(null)
const harnessLoading = signal(false)
const harnessError = signal<string | null>(null)

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

function mergeRecent<T>(
  current: T[],
  nextItem: T,
  isSame: (left: T, right: T) => boolean,
  maxItems: number,
) {
  const filtered = current.filter(item => !isSame(item, nextItem))
  return [nextItem, ...filtered].slice(0, maxItems)
}

function updateHarnessData(
  update: (data: HarnessHealthData) => HarnessHealthData,
): void {
  const current = harnessData.value
  if (!current) return
  harnessData.value = update(current)
}

function handleHarnessSSE(): void {
  const evt = lastEvent.value
  if (!evt) return
  const type = evt.type ?? ''
  const payload = (evt as unknown as { payload?: Record<string, unknown> }).payload
  if (!payload) return

  if (type === 'oas:masc:harness:verdict_recorded') {
    const nextItem: HarnessVerdictItem = {
      timestamp:
        typeof payload.timestamp === 'number'
          ? payload.timestamp
          : Date.now() / 1000,
      task_id: String(payload.task_id ?? ''),
      task_title: String(payload.task_title ?? 'task'),
      agent_name: String(payload.agent_name ?? ''),
      gate: String(payload.gate ?? ''),
      verdict: String(payload.verdict ?? ''),
      evaluator_cascade: String(payload.evaluator_cascade ?? ''),
      fallback_reason:
        payload.fallback_reason == null ? null : String(payload.fallback_reason),
    }
    updateHarnessData(data => ({
      ...data,
      recent_verdicts: mergeRecent(
        data.recent_verdicts,
        nextItem,
        (left, right) =>
          left.timestamp === right.timestamp
          && left.task_id === right.task_id
          && left.verdict === right.verdict,
        8,
      ),
    }))
  }

  if (type === 'oas:masc:harness:pre_compact') {
    const nextItem: PreCompactEvent = {
      timestamp:
        typeof payload.timestamp === 'number'
          ? payload.timestamp
          : Date.now() / 1000,
      keeper_name: String(payload.keeper_name ?? ''),
      context_ratio: Number(payload.context_ratio ?? 0),
      message_count: Number(payload.message_count ?? 0),
      token_count: Number(payload.token_count ?? 0),
      strategies: Array.isArray(payload.strategies)
        ? payload.strategies.map(value => String(value))
        : [],
      model_family: String(payload.model_family ?? ''),
      trigger: String(payload.trigger ?? ''),
    }
    updateHarnessData(data => ({
      ...data,
      pre_compact: {
        ...data.pre_compact,
        recent_events: mergeRecent(
          data.pre_compact.recent_events,
          nextItem,
          (left, right) =>
            left.timestamp === right.timestamp
            && left.keeper_name === right.keeper_name
            && left.trigger === right.trigger,
          8,
        ),
      },
    }))
  }

  if (type === 'oas:masc:harness:dna_quality') {
    const nextItem: DnaQualityEvent = {
      timestamp:
        typeof payload.timestamp === 'number'
          ? payload.timestamp
          : Date.now() / 1000,
      keeper_name: String(payload.keeper_name ?? ''),
      score: Number(payload.score ?? 0),
      dimensions:
        payload.dimensions && typeof payload.dimensions === 'object'
          ? payload.dimensions as DnaQualityDimensions
          : {},
    }
    updateHarnessData(data => ({
      ...data,
      dna_quality: {
        ...data.dna_quality,
        recent_events: mergeRecent(
          data.dna_quality.recent_events,
          nextItem,
          (left, right) =>
            left.timestamp === right.timestamp
            && left.keeper_name === right.keeper_name
            && left.score === right.score,
          8,
        ),
      },
    }))
  }
}

function StatCard({ label, value, sub }: { label: string; value: string | number; sub?: string }) {
  return html`
    <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3 text-center">
      <div class="text-2xl font-bold text-[var(--accent)]">${value}</div>
      <div class="mt-1 text-xs text-[var(--text-muted)]">${label}</div>
      ${sub ? html`<div class="mt-0.5 text-xs text-[var(--text-dim)]">${sub}</div>` : null}
    </div>
  `
}

function EmptySignal({ text }: { text: string }) {
  return html`
    <div class="rounded-lg border border-dashed border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2 text-sm text-[var(--text-dim)]">
      ${text}
    </div>
  `
}

function GateChart({ distribution }: { distribution: GateDistribution }) {
  const entries = Object.entries(distribution).sort((a, b) => b[1] - a[1])
  const max = entries[0]?.[1] ?? 1
  if (entries.length === 0) {
    return html`<${EmptySignal} text="아직 verdict 기록이 없습니다." />`
  }
  return html`
    <div class="space-y-2">
      ${entries.map(([gate, count]) => html`
        <div class="flex items-center gap-2">
          <span class="w-20 text-right font-mono text-xs text-[var(--text-muted)]">${gate}</span>
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

function formatTimestamp(ts: number): string {
  return new Date(ts * 1000).toLocaleString('ko-KR', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function verdictTone(verdict: string): string {
  return verdict.startsWith('approve')
    ? 'bg-[var(--ok)]'
    : 'bg-[var(--bad)]'
}

function verdictSummary(verdict: string): string {
  if (!verdict.startsWith('reject:')) return verdict
  return verdict.slice('reject:'.length).trim() || 'reject'
}

function RecentVerdictsList({ items }: { items: HarnessVerdictItem[] }) {
  if (items.length === 0) {
    return html`<${EmptySignal} text="최근 evaluator verdict가 없습니다." />`
  }

  return html`
    <div class="space-y-2">
      ${items.map(item => html`
        <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
          <div class="flex items-start justify-between gap-3">
            <div>
              <div class="text-sm font-medium text-[var(--text-strong)]">${item.task_title || item.task_id}</div>
              <div class="mt-1 text-xs text-[var(--text-muted)]">
                ${item.agent_name || 'agent'} · ${item.gate || 'gate'} · ${item.evaluator_cascade || 'cascade'} · ${formatTimestamp(item.timestamp)}
              </div>
            </div>
            <span class=${`inline-block h-2.5 w-2.5 rounded-full ${verdictTone(item.verdict)}`} />
          </div>
          <div class="mt-2 text-sm text-[var(--text-body)]">${verdictSummary(item.verdict)}</div>
          ${item.fallback_reason ? html`
            <div class="mt-2 break-all text-xs text-[var(--warn)]">${item.fallback_reason}</div>
          ` : null}
        </div>
      `)}
    </div>
  `
}

function PreCompactList({ section }: { section: HarnessSignalSection<PreCompactEvent> }) {
  if (section.recent_events.length === 0) {
    return html`<${EmptySignal} text="최근 pre-compaction 신호가 없습니다." />`
  }

  return html`
    <div class="space-y-2">
      ${section.recent_events.map(item => html`
        <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
          <div class="flex items-start justify-between gap-3">
            <div class="text-sm font-medium text-[var(--text-strong)]">${item.keeper_name}</div>
            <div class="text-xs text-[var(--text-muted)]">${formatTimestamp(item.timestamp)}</div>
          </div>
          <div class="mt-2 grid grid-cols-2 gap-2 text-xs text-[var(--text-body)]">
            <span>ratio ${item.context_ratio.toFixed(3)}</span>
            <span>messages ${item.message_count}</span>
            <span>tokens ${item.token_count}</span>
            <span>${item.model_family || 'model 미상'}</span>
          </div>
          <div class="mt-2 text-xs text-[var(--text-muted)]">${item.trigger}</div>
          ${item.strategies.length > 0 ? html`
            <div class="mt-2 flex flex-wrap gap-1">
              ${item.strategies.map(strategy => html`
                <span class="rounded-full border border-[var(--white-8)] px-2 py-0.5 text-[10px] text-[var(--text-muted)]">${strategy}</span>
              `)}
            </div>
          ` : null}
        </div>
      `)}
    </div>
  `
}

function DnaQualityList({ section }: { section: HarnessSignalSection<DnaQualityEvent> }) {
  if (section.recent_events.length === 0) {
    return html`<${EmptySignal} text="최근 DNA quality 신호가 없습니다." />`
  }

  return html`
    <div class="space-y-2">
      ${section.recent_events.map(item => html`
        <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
          <div class="flex items-start justify-between gap-3">
            <div class="text-sm font-medium text-[var(--text-strong)]">${item.keeper_name}</div>
            <div class="text-xs text-[var(--text-muted)]">${formatTimestamp(item.timestamp)}</div>
          </div>
          <div class="mt-2 text-sm text-[var(--text-body)]">score ${item.score.toFixed(2)}</div>
          <div class="mt-2 flex flex-wrap gap-1 text-[10px]">
            <span class="rounded-full border border-[var(--white-8)] px-2 py-0.5 text-[var(--text-muted)]">
              goal ${item.dimensions.has_goal_anchor ? 'yes' : 'no'}
            </span>
            <span class="rounded-full border border-[var(--white-8)] px-2 py-0.5 text-[var(--text-muted)]">
              task ${item.dimensions.has_task_anchor ? 'yes' : 'no'}
            </span>
            <span class="rounded-full border border-[var(--white-8)] px-2 py-0.5 text-[var(--text-muted)]">
              recent ${item.dimensions.has_recent_context ? 'yes' : 'no'}
            </span>
            <span class="rounded-full border border-[var(--white-8)] px-2 py-0.5 text-[var(--text-muted)]">
              truncation ${item.dimensions.truncation_artifacts ?? 0}
            </span>
            <span class="rounded-full border border-[var(--white-8)] px-2 py-0.5 text-[var(--text-muted)]">
              length ${item.dimensions.content_length ?? 0}
            </span>
          </div>
        </div>
      `)}
    </div>
  `
}

export function HarnessHealth() {
  useEffect(() => { void loadHarnessHealth() }, [])
  useEffect(handleHarnessSSE, [lastEvent.value])

  const data = harnessData.value
  const cal = data?.calibration
  const rejectRate = cal && cal.total_verdicts > 0
    ? ((cal.reject_count / cal.total_verdicts) * 100).toFixed(1)
    : '0'
  const agreementPct = cal ? (cal.agreement_rate * 100).toFixed(1) : '-'
  const fallbackCount = cal?.fallback_count ?? 0
  const isFallbackDominant = cal != null && cal.total_verdicts > 0
    && (fallbackCount / cal.total_verdicts) > 0.8
  const fallbackReasons = cal?.recent_fallback_reasons ?? []

  return html`
    <div class="space-y-4">
      <${Card} title="Safety Harness" class="section">
        ${harnessLoading.value ? html`
          <div class="text-sm text-[var(--text-dim)]">로딩 중...</div>
        ` : harnessError.value ? html`
          <div class="text-sm text-[var(--bad)]">${harnessError.value}</div>
        ` : !data ? html`
          <${EmptySignal} text="Harness 데이터가 없습니다." />
        ` : html`
          <div class="space-y-3">
            <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] px-4 py-3 text-sm leading-[1.6] text-[var(--text-body)]">
              ${data.scope_note}
            </div>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-3 text-xs">
              <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
                <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-muted)]">Autoresearch가 답하는 것</div>
                <div class="text-[var(--text-body)] leading-relaxed">
                  어떤 파일을 어떻게 바꿔서 어떤 metric을 개선하려는지, 그리고 cycle별 keep/discard가 어땠는지.
                </div>
              </div>
              <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] p-3">
                <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-muted)]">Harness가 답하는 것</div>
                <div class="text-[var(--text-body)] leading-relaxed">
                  evaluator가 건강한지, 장기 keeper turn에서 compaction이 어떻게 걸리는지, continuity DNA가 얼마나 안전한지.
                </div>
              </div>
            </div>
            <div class="text-xs text-[var(--text-dim)]">
              generated ${formatTimestamp(data.generated_at)}
            </div>
          </div>
        `}
      <//>

      <${Card} title="Evaluator Calibration" class="section">
        ${!cal ? html`
          <${EmptySignal} text="Evaluator calibration 데이터가 없습니다." />
        ` : html`
          ${isFallbackDominant ? html`
            <div class="mb-4 rounded-lg border border-[var(--warn-30)] bg-[var(--warn-12)] px-4 py-3">
              <div class="mb-1 text-sm font-medium text-[var(--warn)]">Evaluator 미연결</div>
              <div class="text-xs text-[var(--warn)]">
                전체 ${cal.total_verdicts}건 중 ${fallbackCount}건이 fallback으로 처리됐습니다.
                지금은 LLM evaluator가 자주 빠져서 calibration 신뢰도가 낮습니다.
              </div>
              ${fallbackReasons.length > 0 ? html`
                <details class="mt-2">
                  <summary class="cursor-pointer text-xs text-[var(--warn)] opacity-70">최근 에러 (${fallbackReasons.length}건)</summary>
                  <div class="mt-1 space-y-1">
                    ${fallbackReasons.map(reason => html`
                      <div class="break-all font-mono text-xs text-[var(--warn)] opacity-70">${reason}</div>
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

          <div class="mb-2 text-xs uppercase tracking-wider text-[var(--text-dim)]">Gate 분포</div>
          <${GateChart} distribution=${cal.gate_distribution} />

          <div class="mt-4 mb-2 text-xs uppercase tracking-wider text-[var(--text-dim)]">최근 Verdict</div>
          <${RecentVerdictsList} items=${data?.recent_verdicts ?? []} />

          <button
            class="mt-3 text-xs text-[var(--text-muted)] transition-colors hover:text-[var(--accent)]"
            onClick=${() => void loadHarnessHealth()}
          >새로고침</button>
        `}
      <//>

      <${Card} title="Pre-Compaction Rail" class="section">
        ${data ? html`
          <div class="mb-3 text-sm leading-[1.6] text-[var(--text-muted)]">${data.pre_compact.description}</div>
          <${PreCompactList} section=${data.pre_compact} />
        ` : html`<${EmptySignal} text="Pre-compaction 데이터가 없습니다." />`}
      <//>

      <${Card} title="DNA Quality Rail" class="section">
        ${data ? html`
          <div class="mb-3 text-sm leading-[1.6] text-[var(--text-muted)]">${data.dna_quality.description}</div>
          <${DnaQualityList} section=${data.dna_quality} />
        ` : html`<${EmptySignal} text="DNA quality 데이터가 없습니다." />`}
      <//>
    </div>
  `
}
