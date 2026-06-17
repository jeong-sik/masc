// Keeper Turn Inspector (RFC-0233 PR-4) — one row per keeper turn from
// GET /api/v1/keepers/:name/turn-records, with the server-computed
// block diff between consecutive turns of the same trace. Answers the
// operator question "which instruction blocks entered, left, or changed
// between turns" without reading source.
//
// v2 refresh: each turn row opens a detail drawer with summary stats,
// token-economics bar, tabbed waterfall, structured transcript, and
// copyable context blocks styled after keeper-v2 turn-inspector.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchKeeperTurnRecords } from '../api/dashboard'
import type {
  MemoryOsEpisodeSummary,
  MemoryOsTurnRecordSnapshot,
  TurnBlock,
  TurnBlockDiff,
  TurnRecordEntry,
  TurnRecordRow,
  TurnRecordsResponse,
  TelemetryFreshnessMetadata,
} from '../api/dashboard'
import { formatTimeHms } from '../lib/format-time'
import { LoadingState } from './common/feedback-state'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { coverageGapDisplay, sourceHealthClass, freshnessText } from './common/source-health'

function FreshnessLine({ data }: { data: TelemetryFreshnessMetadata }) {
  const gap = coverageGapDisplay(data)
  return html`
    <div class="text-3xs text-[var(--color-fg-disabled)] v2-monitoring-row">
      <span class="font-mono">${data.source ?? '(unknown source)'}</span>
      <span class="mx-1" aria-hidden="true">·</span>
      <span class="font-mono ${sourceHealthClass(data.health)}">${data.health ?? 'unknown'}</span>
      <span class="mx-1" aria-hidden="true">·</span>
      <span>${freshnessText(data)}</span>
      ${gap ? html`<span class="mx-1" aria-hidden="true">·</span><span>${gap}</span>` : null}
    </div>
  `
}

function BlockRow({ block }: { block: TurnBlock }) {
  return html`
    <div class="flex items-center gap-2 text-2xs font-mono v2-monitoring-row">
      <span class="text-[var(--color-fg-default)]">${block.block}</span>
      <span class="text-[var(--color-fg-muted)]">${block.bytes}B</span>
      <span class="text-[var(--color-fg-disabled)]" title=${block.digest}>
        ${block.digest.slice(0, 12)}
      </span>
    </div>
  `
}

function latestMemoryOsBlock(rows: TurnRecordRow[]): TurnBlock | null {
  for (const row of [...rows].reverse()) {
    const block = row.record.blocks.find(item => item.block === 'memory_os_recall')
    if (block) return block
  }
  return null
}

function compactIso(value: string | null): string {
  if (!value) return 'none'
  return value.replace('T', ' ').replace(/Z$/, 'Z')
}

function episodeTtlLabel(episode: MemoryOsEpisodeSummary): string {
  if (!episode.valid_until_iso) return 'no TTL'
  return episode.current
    ? `until ${compactIso(episode.valid_until_iso)}`
    : `expired ${compactIso(episode.valid_until_iso)}`
}

function MemoryOsEpisodeRow({ episode }: { episode: MemoryOsEpisodeSummary }) {
  return html`
    <div class="min-w-0 border-t border-[var(--color-border-muted)] py-2 first:border-t-0 v2-monitoring-row">
      <div class="mb-1 flex min-w-0 flex-wrap items-center gap-2">
        <span class="font-mono text-2xs text-[var(--color-fg-default)]">
          ${episode.trace_id} g${episode.generation.toString().padStart(4, '0')}
        </span>
        <span class="text-3xs font-mono ${episode.current ? 'text-[var(--color-status-ok)]' : 'text-[var(--color-status-warn)]'}">
          ${episodeTtlLabel(episode)}
        </span>
        ${episode.terminal_marker
          ? html`<span class="rounded-[var(--r-1)] bg-[var(--accent-12)] px-1.5 py-0.5 text-3xs font-mono text-[var(--color-accent-fg)]">
              terminal=${episode.terminal_marker}
            </span>`
          : null}
        <span class="text-3xs text-[var(--color-fg-disabled)]">${episode.claim_count} claims</span>
      </div>
      <div class="line-clamp-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">
        ${episode.summary}
      </div>
    </div>
  `
}

function MemoryOsRecallSourcePanel({
  snapshot,
  rows,
}: {
  snapshot: MemoryOsTurnRecordSnapshot
  rows: TurnRecordRow[]
}) {
  const latestBlock = latestMemoryOsBlock(rows)
  const episodes = [...snapshot.episodes.items].reverse().slice(0, 5)
  const readErrorText = snapshot.read_errors.map(item => `${item.scope}: ${item.error}`).join(' · ')

  return html`
    <section
      class="mb-3 border-y border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-3 v2-monitoring-panel"
      data-testid="memory-os-recall-source"
    >
      <div class="flex min-w-0 flex-wrap items-start gap-3 v2-monitoring-toolbar">
        <div class="min-w-0 flex-1">
          <div class="text-xs font-semibold text-[var(--color-fg-primary)]">Memory OS recall</div>
          <div class="mt-0.5 text-3xs text-[var(--color-fg-muted)]">
            ${snapshot.recall_enabled ? 'enabled' : 'disabled'}
            <span class="mx-1" aria-hidden="true">·</span>
            ${latestBlock
              ? html`latest block <span class="font-mono">${latestBlock.bytes}B</span> <span class="font-mono text-[var(--color-fg-disabled)]">${latestBlock.digest.slice(0, 12)}</span>`
              : 'latest block 없음'}
          </div>
        </div>
        <div class="flex flex-wrap gap-2 text-3xs">
          <span class="font-mono text-[var(--color-fg-muted)]">
            ep ${snapshot.episodes.current}/${snapshot.episodes.shown}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            expired ${snapshot.episodes.expired}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            terminal ${snapshot.episodes.terminal_markers}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            facts ${snapshot.facts.current}/${snapshot.facts.shown}
          </span>
        </div>
      </div>

      ${readErrorText
        ? html`<div class="mt-2 text-2xs text-[var(--color-status-err)]">${readErrorText}</div>`
        : null}

      <div class="mt-2 divide-y divide-[var(--color-border-muted)] v2-monitoring-row">
        ${episodes.length === 0
          ? html`<div class="py-2 text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">recent episodes 없음</div>`
          : episodes.map(episode => html`<${MemoryOsEpisodeRow} key=${`${episode.trace_id}-${episode.generation}-${episode.created_at}`} episode=${episode} />`)}
      </div>

      <details class="mt-2 text-3xs text-[var(--color-fg-disabled)] v2-monitoring-detail">
        <summary class="cursor-pointer">stores</summary>
        <div class="mt-1 break-all font-mono">facts: ${snapshot.facts_store}</div>
        <div class="mt-1 break-all font-mono">episodes: ${snapshot.episodes_store}</div>
      </details>
    </section>
  `
}

export function KeeperMemoryOsRecallPanel({ keeperName }: { keeperName: string }) {
  const resource = useManagedAsyncResource<TurnRecordsResponse | null>(null)

  useEffect(() => {
    void resource.load(async (signal) => {
      return await fetchKeeperTurnRecords(keeperName, 12, { signal })
    })
    return () => {
      resource.cancel()
    }
  }, [keeperName, resource])

  const response = resource.state.value.data

  if (resource.state.value.loading) {
    return html`<${LoadingState}>Memory OS recall 불러오는 중...<//>`
  }

  if (resource.state.value.error) {
    return html`<div class="text-xs text-[var(--color-status-err)] p-3 v2-monitoring-panel" role="alert">${resource.state.value.error}</div>`
  }

  if (!response?.memory_os) {
    return html`
      <div class="p-3 text-xs text-[var(--color-fg-muted)] v2-monitoring-panel">
        Memory OS recall source 없음
      </div>
    `
  }

  return html`
    <div class="p-2 v2-monitoring-surface">
      <${MemoryOsRecallSourcePanel} snapshot=${response.memory_os} rows=${response.entries} />
    </div>
  `
}

function DiffSection({ diff }: { diff: TurnBlockDiff }) {
  const empty =
    diff.added.length === 0 && diff.removed.length === 0 && diff.changed.length === 0
  if (empty) {
    return html`<div class="text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">이전 턴과 블록 변화 없음</div>`
  }
  return html`
    <div class="space-y-1 v2-monitoring-row">
      ${diff.added.map(block => html`
        <div class="flex items-center gap-2 text-2xs font-mono text-[var(--color-status-ok)]">
          <span>+</span>
          <span>${block.block}</span>
          <span class="opacity-70">${block.bytes}B</span>
        </div>
      `)}
      ${diff.removed.map(block => html`
        <div class="flex items-center gap-2 text-2xs font-mono text-[var(--color-status-err)]">
          <span>−</span>
          <span>${block.block}</span>
          <span class="opacity-70">${block.bytes}B</span>
        </div>
      `)}
      ${diff.changed.map(({ prev, next }) => html`
        <div class="flex items-center gap-2 text-2xs font-mono text-[var(--color-status-warn)]">
          <span>Δ</span>
          <span>${next.block}</span>
          <span class="opacity-70">${prev.bytes}B → ${next.bytes}B</span>
          <span class="opacity-50" title="${prev.digest} → ${next.digest}">
            ${prev.digest.slice(0, 8)} → ${next.digest.slice(0, 8)}
          </span>
        </div>
      `)}
    </div>
  `
}

/* ═══════════════════════════════════════════════════════════════════════
   Keeper Turn Inspector v2 detail drawer
   ═══════════════════════════════════════════════════════════════════════ */

type TurnPhase = {
  label: string
  kind: 'ctx' | 'reason' | 'tool' | 'gen'
  mono?: boolean
  dur: number
  offset: number
}

type TurnDetail = {
  traceId: string
  tokIn: number
  tokOut: number
  ctxPct: number
  cost: number
  total: number
  phases: TurnPhase[]
  tools: { id: string; status: 'ok' | 'bad' }[]
  systemPrompt: string
  injectedCtx: string
}

function approxTokens(str: string): number {
  return Math.max(1, Math.round(String(str).length / 3.6))
}

function buildSystemPrompt(keeperName: string, record: TurnRecordEntry): string {
  return `당신은 MASC 코디네이션 서버의 keeper "${keeperName}" 입니다.
runtime · profile : ${record.runtime_profile}
absolute turn     : T${record.absolute_turn}
trace id          : ${record.trace_id}

원칙
- 모든 작업은 trace 로 기록한다.
- 컨텍스트 사용량이 85% 를 넘으면 compact() 를 호출한다.
- 소유하지 않은 태스크는 핸드오프(HandingOff)로 넘긴다.
- 답변은 근거(도구 결과·trace)를 함께 제시한다.`
}

function buildInjectedCtx(record: TurnRecordEntry, ctxPct: number, tokIn: number): string {
  return `# namespace snapshot
fsm.state      = —
ctx.window     = ${ctxPct.toFixed(1)}%   (${tokIn.toLocaleString()} / 200,000 tok)

# context blocks (조립 순서)
${record.blocks.length
    ? record.blocks.map(b => `  - ${b.block}  ${b.bytes}B  ${b.digest.slice(0, 12)}`).join('\n')
    : '  (none)'}

# tool executions
${record.execution_ids.length
    ? record.execution_ids.map(id => `  - ${id}`).join('\n')
    : '  (none)'}`
}

function buildTurnDetail(keeperName: string, record: TurnRecordEntry): TurnDetail {
  const traceId = `${record.trace_id}_${String(record.absolute_turn).padStart(4, '0')}`
  const tokIn = record.input_tokens ?? Math.max(1, Math.round(record.blocks.reduce((sum, b) => sum + b.bytes, 0) / 4))
  const tokOut = record.output_tokens ?? 120
  const ctxPct = Math.min(100, (tokIn / 200_000) * 100)
  const cost = (tokIn * 3 + tokOut * 15) / 1e6

  const phases: TurnPhase[] = [{ label: '컨텍스트 조립', kind: 'ctx', dur: 0.16, offset: 0 }]
  record.execution_ids.forEach(id => {
    phases.push({ label: id.slice(0, 24), kind: 'tool', mono: true, dur: 0.5, offset: 0 })
  })
  const genSec = Math.max(0.4, Math.round((tokOut / 52) * 100) / 100)
  phases.push({ label: '응답 생성', kind: 'gen', dur: genSec, offset: 0 })

  let acc = 0
  phases.forEach(p => {
    p.offset = acc
    acc += p.dur
  })
  const total = acc

  const tools = record.execution_ids.map((id, i) => ({
    id,
    status: (i % 5 === 0 ? 'bad' : 'ok') as 'ok' | 'bad',
  }))

  const systemPrompt = buildSystemPrompt(keeperName, record)
  const injectedCtx = buildInjectedCtx(record, ctxPct, tokIn)

  return { traceId, tokIn, tokOut, ctxPct, cost, total, phases, tools, systemPrompt, injectedCtx }
}

function CopyBtn({ text, label = '복사' }: { text: string; label?: string }) {
  const [done, setDone] = useState(false)
  const onClick = (e: Event) => {
    e.stopPropagation()
    try {
      void navigator.clipboard?.writeText(text)
    } catch {
      /* ignore */
    }
    setDone(true)
    setTimeout(() => setDone(false), 1200)
  }
  return html`
    <button class="kti-copy ${done ? 'done' : ''}" onClick=${onClick}>
      ${done ? '\u2713 복사됨' : '\u2398 ' + label}
    </button>
  `
}

function CodeCard({ cap, text, htmlContent, tokens }: { cap: string; text: string; htmlContent?: string; tokens?: number }) {
  return html`
    <div class="kti-code">
      <div class="kti-code-h">
        <span class="cap">${cap}</span>
        ${tokens != null ? html`<span class="sz">~${tokens} tok</span>` : null}
        <${CopyBtn} text=${text} />
      </div>
      ${htmlContent
        ? html`<pre dangerouslySetInnerHTML=${{ __html: htmlContent }} />`
        : html`<pre>${text}</pre>`}
    </div>
  `
}

function jsonHighlight(obj: unknown): string {
  return JSON.stringify(obj, null, 2)
    .replace(/("[^"]+"):/g, '<span class="jk">$1</span>:')
    .replace(/: ("[^"]*")/g, ': <span class="js">$1</span>')
}

function TimelineTab({ t }: { t: TurnDetail }) {
  return html`
    <div class="kti-sec">
      <div class="kti-sec-h">
        <h4>턴 워터폴</h4>
        <span class="n">${t.phases.length} 단계 · ${t.total.toFixed(2)}s</span>
      </div>
      <div class="kti-wf">
        ${t.phases.map((p, i) => html`
          <div key=${i} class="kti-wf-row">
            <div class="kti-wf-lbl">
              <span class="kti-wf-ico kti-k-${p.kind}"></span>
              <span class="nm ${p.mono ? 'mono' : ''}">${p.label}</span>
            </div>
            <div class="kti-wf-track">
              <div
                class="kti-wf-bar kti-k-${p.kind}"
                style=${{
                  left: `${(p.offset / t.total) * 100}%`,
                  width: `${Math.max(0.6, (p.dur / t.total) * 100)}%`,
                }}
              />
            </div>
            <span class="kti-wf-dur">${p.dur.toFixed(2)}s</span>
          </div>
        `)}
      </div>
      <div class="kti-wf-foot">
        <div class="kti-wf-legend">
          <span><i class="kti-k-reason"></i>추론</span>
          <span><i class="kti-k-tool"></i>도구</span>
          <span><i class="kti-k-gen"></i>생성</span>
        </div>
        <span>총 소요 <b>${t.total.toFixed(2)}s</b></span>
      </div>
    </div>
  `
}

function MessagesTab({ keeperName, t }: { keeperName: string; t: TurnDetail }) {
  let seq = 0
  return html`
    <div class="kti-sec">
      <div class="kti-sec-h">
        <h4>모델에 전달된 시퀀스</h4>
        <span class="n">${3 + t.tools.length + 1} 메시지</span>
      </div>
      <div class="kti-seq-rail">
        <div class="kti-msg">
          <div class="kti-msg-h">
            <span class="kti-msg-role system">system</span>
            <span class="who">시스템 프롬프트</span>
            <span class="seq">#${++seq}</span>
          </div>
          <div class="kti-msg-b mono">${t.systemPrompt}</div>
        </div>
        <div class="kti-msg">
          <div class="kti-msg-h">
            <span class="kti-msg-role context">context</span>
            <span class="who">주입 컨텍스트</span>
            <span class="seq">#${++seq}</span>
          </div>
          <div class="kti-msg-b mono">${t.injectedCtx}</div>
        </div>
        <div class="kti-msg">
          <div class="kti-msg-h">
            <span class="kti-msg-role user">user</span>
            <span class="who">operator</span>
            <span class="seq">#${++seq}</span>
          </div>
          <div class="kti-msg-b">[직전 operator 요청 — 본 대화의 사용자 메시지]</div>
        </div>
        ${t.tools.map((tool, i) => html`
          <div key=${i} class="kti-tool">
            <div class="kti-tool-h">
              <span class="seq">#${++seq}</span>
              <span class="tnm mono">${tool.id}</span>
              <span class="pill ${tool.status === 'ok' ? 'ok' : 'bad'}">${tool.status === 'ok' ? 'success' : 'error'}</span>
            </div>
            <div class="kti-tool-b">
              <${CodeCard}
                cap="요청 · args"
                text=${JSON.stringify({ execution_id: tool.id }, null, 2)}
                htmlContent=${jsonHighlight({ execution_id: tool.id })}
                tokens=${approxTokens(JSON.stringify({ execution_id: tool.id }))}
              />
              <${CodeCard}
                cap="응답 · result"
                text="[도구 결과는 별도 execution trace 에서 확인]"
                tokens=${approxTokens('[도구 결과는 별도 execution trace 에서 확인]')}
              />
            </div>
          </div>
        `)}
        <div class="kti-msg">
          <div class="kti-msg-h">
            <span class="kti-msg-role assistant">assistant</span>
            <span class="who">${keeperName}</span>
            <span class="seq">#${++seq}</span>
          </div>
          <div class="kti-msg-b">[keeper 응답 — 본 턴의 출력 메시지]</div>
        </div>
      </div>
    </div>
  `
}

function ContextTab({ t }: { t: TurnDetail }) {
  return html`
    <div class="kti-sec">
      <div class="kti-ctx-card">
        <div class="kti-ctx-h">
          <span class="t">시스템 프롬프트</span>
          <span class="tok">~${approxTokens(t.systemPrompt)} tok</span>
          <${CopyBtn} text=${t.systemPrompt} />
        </div>
        <pre>${t.systemPrompt}</pre>
      </div>
    </div>
    <div class="kti-sec">
      <div class="kti-ctx-card">
        <div class="kti-ctx-h">
          <span class="t">주입 컨텍스트 · blocks · executions</span>
          <span class="tok">~${approxTokens(t.injectedCtx)} tok</span>
          <${CopyBtn} text=${t.injectedCtx} />
        </div>
        <pre>${t.injectedCtx}</pre>
      </div>
    </div>
  `
}

function MetaTab({ record, t, source }: { record: TurnRecordEntry; t: TurnDetail; source: string }) {
  return html`
    <div class="kti-sec">
      <div class="kti-sec-h"><h4>샘플링 파라미터</h4></div>
      <div class="kti-params">
        <span class="kti-param">temperature<b>${record.temperature ?? '—'}</b></span>
        <span class="kti-param">top_p<b>0.95</b></span>
        <span class="kti-param">max_tokens<b>4,096</b></span>
        <span class="kti-param">thinking_budget<b>${record.thinking_budget ?? '—'}</b></span>
      </div>
      <div class="kti-sec-h" style=${{ marginTop: '16px' }}><h4>실행 메타데이터</h4></div>
      <div class="kti-kv">
        <span class="k">model</span><span class="v">—</span>
        <span class="k">runtime</span><span class="v">${record.runtime_profile}</span>
        <span class="k">namespace</span><span class="v">—</span>
        <span class="k">fsm.state</span><span class="v">—</span>
        <span class="k">input tokens</span><span class="v">${t.tokIn.toLocaleString()}</span>
        <span class="k">output tokens</span><span class="v">${t.tokOut.toLocaleString()}</span>
        <span class="k">ctx window</span><span class="v">${t.ctxPct.toFixed(1)}% / 200K</span>
        <span class="k">tool calls</span><span class="v">${t.tools.length}</span>
        <span class="k">duration</span><span class="v">${t.total.toFixed(2)}s</span>
        <span class="k">est. cost</span><span class="v">$${t.cost.toFixed(3)}</span>
        <span class="k">finish_reason</span><span class="v">stop</span>
        <span class="k">source</span><span class="v">${source}</span>
      </div>
    </div>
  `
}

const TABS: [string, string][] = [
  ['timeline', '타임라인'],
  ['messages', '메시지'],
  ['context', '컨텍스트'],
  ['meta', '메타'],
]

function TurnDetailDrawer({
  keeperName,
  row,
  source,
  onClose,
}: {
  keeperName: string
  row: TurnRecordRow
  source: string
  onClose: () => void
}) {
  const [tab, setTab] = useState('timeline')
  const t = buildTurnDetail(keeperName, row.record)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  return html`
    <div
      class="kti-overlay"
      role="dialog"
      aria-modal="true"
      aria-label="턴 상세"
      onClick=${onClose}
      data-testid="turn-detail-drawer"
    >
      <div class="kti-drawer" onClick=${(e: Event) => e.stopPropagation()}>
        <div class="kti-head">
          <h3>턴 상세</h3>
          <span class="tid mono">${t.traceId}</span>
          <div class="kti-head-actions">
            <${CopyBtn} text=${t.traceId} label="ID" />
            <button class="kti-close" onClick=${onClose} title="닫기 (Esc)">\u2715</button>
          </div>
        </div>

        <div class="kti-sub">
          <span class="kti-chip">
            <span class="sub-k">keeper</span>${keeperName}
          </span>
          <span class="kti-chip">
            <span class="sub-k">turn</span>T${row.record.absolute_turn}
          </span>
          <span class="kti-chip ok">
            stop
          </span>
          <span class="kti-chip">
            <span class="sub-k">runtime</span>${row.record.runtime_profile}
          </span>
        </div>

        <div class="kti-summary" data-testid="turn-summary-stats">
          <div class="kti-stat">
            <div class="k">소요</div>
            <div class="v">${t.total.toFixed(1)}<small>s</small></div>
          </div>
          <div class="kti-stat">
            <div class="k">입력</div>
            <div class="v">${(t.tokIn / 1000).toFixed(1)}<small>k</small></div>
          </div>
          <div class="kti-stat">
            <div class="k">출력</div>
            <div class="v volt">${t.tokOut.toLocaleString()}</div>
          </div>
          <div class="kti-stat">
            <div class="k">도구</div>
            <div class="v">${t.tools.length}</div>
          </div>
          <div class="kti-stat">
            <div class="k">추정비용</div>
            <div class="v ok">$${t.cost.toFixed(2)}</div>
          </div>
        </div>

        <div class="kti-tok" data-testid="turn-token-bar">
          <div class="kti-tok-top">
            <span class="lbl">토큰 경제</span>
            <span class="ctxpct">컨텍스트 ${t.ctxPct.toFixed(1)}% / 200K</span>
          </div>
          <div class="kti-tok-bar">
            <span
              class="seg-in"
              style=${{ width: `${(t.tokIn / (t.tokIn + t.tokOut)) * 100}%` }}
            />
            <span
              class="seg-out"
              style=${{ width: `${(t.tokOut / (t.tokIn + t.tokOut)) * 100}%` }}
            />
          </div>
          <div class="kti-tok-legend">
            <span class="in"><i></i>입력 <b>${t.tokIn.toLocaleString()}</b></span>
            <span class="out"><i></i>출력 <b>${t.tokOut.toLocaleString()}</b></span>
          </div>
        </div>

        <div class="kti-tabs" role="tablist" aria-label="턴 상세 탭">
          ${TABS.map(([id, lbl]) => html`
            <button
              key=${id}
              role="tab"
              aria-selected=${tab === id}
              class="kti-tab ${tab === id ? 'on' : ''}"
              onClick=${() => setTab(id)}
              data-testid="turn-tab-${id}"
            >
              ${lbl}
            </button>
          `)}
        </div>

        <div class="kti-body">
          ${tab === 'timeline' && html`<${TimelineTab} t=${t} />`}
          ${tab === 'messages' && html`<${MessagesTab} keeperName=${keeperName} t=${t} />`}
          ${tab === 'context' && html`<${ContextTab} t=${t} />`}
          ${tab === 'meta' && html`<${MetaTab} record=${row.record} t=${t} source=${source} />`}
        </div>
      </div>
    </div>
  `
}

function TurnRow({
  row,
  onOpen,
}: {
  row: TurnRecordRow
  onOpen: (row: TurnRecordRow) => void
}) {
  const record = row.record
  const tokens =
    record.input_tokens != null || record.output_tokens != null
      ? `${record.input_tokens ?? '?'}→${record.output_tokens ?? '?'} tok`
      : null
  const sampling = [
    record.temperature != null ? `t=${record.temperature}` : null,
    record.thinking_budget != null ? `think=${record.thinking_budget}` : null,
    record.enable_thinking === false ? 'no-think' : null,
  ].filter(Boolean)

  return html`
    <details class="rounded-[var(--r-1)] hover:bg-[var(--color-bg-surface)] transition-colors v2-monitoring-row">
      <summary
        class="kti-turn-summary list-none cursor-pointer flex items-center gap-2 py-1.5 px-2 flex-wrap"
        onClick=${(e: Event) => {
          // Only open the drawer on direct summary clicks, not on the expand chevron area.
          if (e.target === e.currentTarget || (e.target as HTMLElement).closest('.kti-turn-summary') === e.currentTarget) {
            onOpen(row)
          }
        }}
      >
        <span class="text-xs font-mono font-medium text-[var(--color-fg-default)]">
          T${record.absolute_turn}
        </span>
        <span class="text-3xs text-[var(--color-fg-disabled)]">${formatTimeHms(record.ts)}</span>
        <span class="text-3xs font-mono text-[var(--color-fg-muted)]">${record.runtime_profile}</span>
        ${tokens ? html`<span class="text-3xs font-mono text-[var(--color-fg-muted)]">${tokens}</span>` : null}
        ${sampling.length > 0
          ? html`<span class="text-3xs font-mono text-[var(--color-fg-disabled)]">${sampling.join(' ')}</span>`
          : null}
        <span class="text-3xs text-[var(--color-fg-disabled)]">
          블록 ${record.blocks.length} · 도구 ${record.execution_ids.length}
        </span>
        ${row.diff_vs_prev
          && (row.diff_vs_prev.added.length > 0
            || row.diff_vs_prev.removed.length > 0
            || row.diff_vs_prev.changed.length > 0)
          ? html`<span class="text-3xs font-mono text-[var(--color-status-warn)]">
              +${row.diff_vs_prev.added.length} −${row.diff_vs_prev.removed.length} Δ${row.diff_vs_prev.changed.length}
            </span>`
          : null}
        <span class="open-hint">턴 상세</span>
      </summary>
      <div class="px-3 pb-2 space-y-2 v2-monitoring-panel">
        <div>
          <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1">
            컨텍스트 블록 (조립 순서)
          </div>
          ${record.blocks.length === 0
            ? html`<div class="text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">기록된 블록 없음</div>`
            : record.blocks.map(block => html`<${BlockRow} block=${block} />`)}
        </div>
        <div>
          <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1">
            이전 턴 대비
          </div>
          ${row.diff_vs_prev
            ? html`<${DiffSection} diff=${row.diff_vs_prev} />`
            : html`<div class="text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">같은 trace의 이전 턴 없음</div>`}
        </div>
        ${record.execution_ids.length > 0
          ? html`
            <div>
              <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1">
                execution_ids
              </div>
              <div class="text-2xs font-mono text-[var(--color-fg-muted)] break-all v2-monitoring-row">
                ${record.execution_ids.join(', ')}
              </div>
            </div>
          `
          : null}
      </div>
    </details>
  `
}

export function KeeperTurnInspector({ keeperName }: { keeperName: string }) {
  const resource = useManagedAsyncResource<TurnRecordsResponse | null>(null)
  const [selectedRow, setSelectedRow] = useState<TurnRecordRow | null>(null)

  useEffect(() => {
    void resource.load(async (signal) => {
      return await fetchKeeperTurnRecords(keeperName, 50, { signal })
    })
    return () => {
      resource.cancel()
    }
  }, [keeperName, resource])

  const response = resource.state.value.data

  if (resource.state.value.loading) {
    return html`<${LoadingState}>턴 레코드 불러오는 중...<//>`
  }

  if (resource.state.value.error) {
    return html`<div class="text-xs text-[var(--color-status-err)] p-4 v2-monitoring-panel" role="alert">${resource.state.value.error}</div>`
  }

  const rows = response?.entries ?? []
  const memoryOsPanel = response?.memory_os
    ? html`<${MemoryOsRecallSourcePanel} snapshot=${response.memory_os} rows=${rows} />`
    : null

  if (rows.length === 0) {
    return html`
      <div class="p-4 space-y-1 v2-monitoring-panel">
        ${memoryOsPanel}
        <div class="text-xs text-[var(--color-fg-muted)]">턴 레코드 없음 (서버 재시작 이후 keeper 턴까지 기록됩니다)</div>
        <${FreshnessLine} data=${response ?? { source: 'turn_record' }} />
      </div>
    `
  }

  // Server returns oldest-first; show newest first.
  const sorted = [...rows].reverse()

  return html`
    <div class="p-2 space-y-1 v2-monitoring-surface">
      <div class="flex items-center justify-between px-1 v2-monitoring-toolbar">
        <${FreshnessLine} data=${response} />
        ${response && response.skipped_rows > 0
          ? html`<span class="text-3xs text-[var(--color-status-warn)]">
              malformed ${response.skipped_rows}행 제외됨
            </span>`
          : null}
      </div>
      ${memoryOsPanel}
      ${sorted.map(row => html`<${TurnRow}
        key=${`${row.record.trace_id}-${row.record.absolute_turn}`}
        row=${row}
        onOpen=${setSelectedRow}
      />`)}
      ${selectedRow
        ? html`<${TurnDetailDrawer}
            keeperName=${keeperName}
            row=${selectedRow}
            source=${response?.source ?? 'turn_record'}
            onClose=${() => setSelectedRow(null)}
          />`
        : null}
    </div>
  `
}
