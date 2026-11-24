/**
 * Opt-In Right Debug Companion Pane (`⌘.`, `380px`, collapsible, default closed `<1280px`)
 * with 4 tabs:
 * 1. `Trace`: Turn/Tool Gantt Waterfall (`/turn-records?limit=60`), paginated `/tool-calls?limit=50`, `/raw-traces` + `/raw-trace`
 * 2. `Context`: 60-turn `uPlot` Context Fill chart + compaction epoch markers + 4-segment Prompt Cache SVG bar + `/last-prompt` & `/provider-input` + `Checkpoints / Clear / Reset`
 * 3. `Memory`: Quick `memory-facts` + `memory-journal` + `memory/act` recovery (`resume|adopt|restart_reading|skip_item|skip_line`)
 * 4. `Config Diff`: Quick Keeper CAS schema dry-run diff
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'
import type uPlot from 'uplot'
import { activeWorkspaceId } from '../../core/auth'
import { UPlotChart, type UPlotSeriesSpec } from '../../components/primitives/uplot-chart'
import { TargetLockedAction } from '../../components/primitives/target-locked-action'
import {
  clearKeeperHistoryAction,
  fetchConfigSchemaApi,
  fetchKeeperCheckpointsApi,
  fetchKeeperLastPromptApi,
  fetchKeeperMemoryFactsApi,
  fetchKeeperMemoryJournalApi,
  fetchKeeperMemoryOsInternalsApi,
  fetchKeeperProviderInputApi,
  fetchKeeperRawTracePageApi,
  fetchKeeperRawTracesApi,
  fetchKeeperToolCallsApi,
  fetchKeeperTurnRecordsApi,
  postConfigPatchApi,
  postKeeperMemoryAct,
  resetKeeperAction,
} from './keepers-api'
import type {
  CheckpointInventoryData,
  ConfigPatchResult,
  ConfigSchemaData,
  DebugCompanionTab,
  KeeperLastPromptData,
  KeeperMemoryFactsData,
  KeeperMemoryJournalData,
  KeeperToolCallsData,
  KeeperTurnRecordsData,
  MemoryActPayload,
  ProviderInputData,
  RawTraceTurnItem,
  TurnRecordItem,
  WorkspaceInspectPayload,
} from './types'

export const COMPANION_DESKTOP_MIN_WIDTH = 1280

export function shouldDefaultOpenCompanion(viewportWidth?: number): boolean {
  const w = viewportWidth ?? (typeof window !== 'undefined' ? window.innerWidth : 1024)
  return w >= COMPANION_DESKTOP_MIN_WIDTH
}

export interface PromptCacheSegments {
  readonly cacheRead: number
  readonly cacheCreate: number
  readonly uncachedInput: number
  readonly output: number
  readonly total: number
  readonly cacheHitPct: number | null
}

export function computePromptCacheSegments(record: TurnRecordItem | null): PromptCacheSegments {
  if (!record) {
    return { cacheRead: 0, cacheCreate: 0, uncachedInput: 0, output: 0, total: 0, cacheHitPct: null }
  }
  const cacheRead = Math.max(0, record.cache_read_input_tokens ?? 0)
  const cacheCreate = Math.max(0, record.cache_creation_input_tokens ?? 0)
  const rawInput = Math.max(0, record.input_tokens ?? 0)
  const uncachedInput = Math.max(0, rawInput - cacheRead - cacheCreate)
  const output = Math.max(0, record.output_tokens ?? 0)
  const total = cacheRead + cacheCreate + uncachedInput + output
  const inputDenom = cacheRead + cacheCreate + uncachedInput
  const cacheHitPct = inputDenom > 0 ? Math.round((cacheRead / inputDenom) * 100) : null
  return { cacheRead, cacheCreate, uncachedInput, output, total, cacheHitPct }
}

/**
 * Builds 60-turn `uPlot.AlignedData` for Context Fill % and detects compaction drops (>25% drop).
 */
export function buildContextFillSeries(records: readonly TurnRecordItem[]): {
  readonly data: uPlot.AlignedData
  readonly compactionTurns: readonly number[]
} {
  const ordered = [...records].sort((a, b) => a.absolute_turn - b.absolute_turn).slice(-60)
  const xs: number[] = []
  const ys: (number | null)[] = []
  const compactionTurns: number[] = []
  let prevPct: number | null = null

  for (const r of ordered) {
    const ts = r.ts > 0 ? r.ts : r.absolute_turn
    const win = r.provider_context_window ?? r.context_window ?? 0
    // `input_tokens` already includes cached tokens (lib/types/turn_record.mli:52-58);
    // do not double-count `cache_read_input_tokens` + `cache_creation_input_tokens`.
    const inp = Math.max(0, r.input_tokens ?? 0)
    const pct = win > 0 && inp > 0 ? Math.min(100, Math.round((inp / win) * 100)) : null
    if (prevPct !== null && pct !== null && prevPct - pct >= 25) {
      compactionTurns.push(r.absolute_turn)
    }
    if (pct !== null) prevPct = pct
    xs.push(ts)
    ys.push(pct)
  }

  return { data: [xs, ys], compactionTurns }
}

const CONTEXT_SERIES: readonly UPlotSeriesSpec[] = [
  { label: 'Context %', colorToken: '--brass-1', width: 2, fillAlpha: 0.16, unit: '%' },
]

export interface KeeperDebugCompanionProps {
  readonly keeperName: string
  readonly onClose: () => void
  readonly onInspect: (payload: WorkspaceInspectPayload) => void
  readonly onMutated?: () => void
}

export function KeeperDebugCompanion(props: KeeperDebugCompanionProps) {
  const { keeperName } = props
  const [tab, setTab] = useState<DebugCompanionTab>('trace')

  // Trace state
  const [turns, setTurns] = useState<KeeperTurnRecordsData | null>(null)
  const [toolCalls, setToolCalls] = useState<KeeperToolCallsData | null>(null)
  const [rawTraces, setRawTraces] = useState<readonly RawTraceTurnItem[]>([])
  const [rawTracePage, setRawTracePage] = useState<Record<string, unknown> | null>(null)
  const [traceError, setTraceError] = useState<string | null>(null)

  // Context state
  const [lastPrompt, setLastPrompt] = useState<KeeperLastPromptData | null>(null)
  const [providerInput, setProviderInput] = useState<ProviderInputData | null>(null)
  const [checkpoints, setCheckpoints] = useState<CheckpointInventoryData | null>(null)
  const [compactionEpochs, setCompactionEpochs] = useState<number | null>(null)
  const [contextStatus, setContextStatus] = useState<string | null>(null)
  const [pendingDanger, setPendingDanger] = useState<'clear' | 'reset' | null>(null)

  // Memory quick state
  const [memFacts, setMemFacts] = useState<KeeperMemoryFactsData | null>(null)
  const [memJournal, setMemJournal] = useState<KeeperMemoryJournalData | null>(null)
  const [memActKind, setMemActKind] = useState<'resume' | 'adopt' | 'restart_reading' | 'skip_line' | 'skip_item'>('resume')
  const [memActObserved, setMemActObserved] = useState('')
  const [memActOffset, setMemActOffset] = useState('0')
  const [memActStatus, setMemActStatus] = useState<string | null>(null)

  // Config Diff state
  const [cfgSchema, setCfgSchema] = useState<ConfigSchemaData | null>(null)
  const [cfgFieldKey, setCfgFieldKey] = useState('')
  const [cfgFieldValue, setCfgFieldValue] = useState('')
  const [cfgDiff, setCfgDiff] = useState<ConfigPatchResult | null>(null)
  const [cfgError, setCfgError] = useState<string | null>(null)

  const loadTrace = useCallback(async () => {
    setTraceError(null)
    const [tr, tc, rt] = await Promise.all([
      fetchKeeperTurnRecordsApi(keeperName, 60),
      fetchKeeperToolCallsApi(keeperName, 50),
      fetchKeeperRawTracesApi(keeperName, 12),
    ])
    if (tr.ok) setTurns(tr.value)
    else setTraceError(tr.error.message)
    if (tc.ok) setToolCalls(tc.value)
    if (rt.ok) setRawTraces(rt.value)
  }, [keeperName])

  const loadContext = useCallback(async () => {
    const [tr, lp, cp, os] = await Promise.all([
      fetchKeeperTurnRecordsApi(keeperName, 60),
      fetchKeeperLastPromptApi(keeperName),
      fetchKeeperCheckpointsApi(keeperName),
      fetchKeeperMemoryOsInternalsApi(keeperName),
    ])
    if (tr.ok) {
      setTurns(tr.value)
      const latestTurnRef = tr.value.entries[0]?.record.turn_ref
      if (latestTurnRef) {
        const pi = await fetchKeeperProviderInputApi(keeperName, latestTurnRef)
        if (pi.ok) setProviderInput(pi.value)
      }
    }
    if (lp.ok) setLastPrompt(lp.value)
    if (cp.ok) setCheckpoints(cp.value)
    if (os.ok) setCompactionEpochs(os.value.compaction.epoch_count)
  }, [keeperName])

  const loadMemory = useCallback(async () => {
    const [mf, mj] = await Promise.all([
      fetchKeeperMemoryFactsApi(keeperName),
      fetchKeeperMemoryJournalApi(keeperName, 20),
    ])
    if (mf.ok) setMemFacts(mf.value)
    if (mj.ok) setMemJournal(mj.value)
  }, [keeperName])

  const loadConfigSchema = useCallback(async () => {
    setCfgError(null)
    const res = await fetchConfigSchemaApi(`keeper:${keeperName}`)
    if (!res.ok) {
      setCfgError(res.error.message)
      return
    }
    setCfgSchema(res.value)
    const firstWritable = res.value.categories.flatMap((c) => c.fields).find((f) => f.writable && !f.secret)
    if (firstWritable && !cfgFieldKey) {
      setCfgFieldKey(firstWritable.full_key)
      setCfgFieldValue(String(firstWritable.current_value ?? ''))
    }
  }, [keeperName, cfgFieldKey])

  useEffect(() => {
    if (tab === 'trace') void loadTrace()
    else if (tab === 'context') void loadContext()
    else if (tab === 'memory') void loadMemory()
    else if (tab === 'config-diff') void loadConfigSchema()
  }, [tab, loadTrace, loadContext, loadMemory, loadConfigSchema])

  const turnRecords = useMemo(
    () => (turns ? turns.entries.map((e) => e.record) : []),
    [turns],
  )

  const maxLatencyMs = useMemo(
    () => Math.max(100, ...turnRecords.map((r) => r.request_latency_ms ?? 0)),
    [turnRecords],
  )

  const ctxChart = useMemo(() => buildContextFillSeries(turnRecords), [turnRecords])
  const cacheSegs = useMemo(() => computePromptCacheSegments(turnRecords[0] ?? null), [turnRecords])

  const handleOpenRawTrace = async (file: string) => {
    const res = await fetchKeeperRawTracePageApi(keeperName, file, 30)
    if (res.ok) {
      setRawTracePage(res.value)
      props.onInspect({
        title: `Raw Trace · ${file}`,
        subtitle: keeperName,
        kind: 'raw_trace',
        data: res.value,
      })
    }
  }

  const handleClearHistory = async () => {
    setContextStatus('대화 컨텍스트 초기화 중…')
    const res = await clearKeeperHistoryAction(keeperName, 'operator_debug_companion_clear', true)
    if (!res.ok) {
      setContextStatus(`Clear 실패: ${res.error.message}`)
      return
    }
    setContextStatus('컨텍스트가 초기화되었습니다.')
    void loadContext()
    props.onMutated?.()
  }

  const handleResetKeeper = async () => {
    setContextStatus('Keeper 리셋 중…')
    const res = await resetKeeperAction(keeperName)
    if (!res.ok) {
      setContextStatus(`Reset 실패: ${res.error.message}`)
      return
    }
    setContextStatus('Keeper 리셋이 완료되었습니다.')
    void loadContext()
    props.onMutated?.()
  }

  const handleMemoryAct = async () => {
    setMemActStatus(null)
    let payload: MemoryActPayload
    if (memActKind === 'resume') {
      payload = { action: 'resume' }
    } else if (memActKind === 'adopt') {
      payload = { action: 'adopt', observed: memActObserved.trim() }
    } else if (memActKind === 'restart_reading') {
      payload = { action: 'restart_reading', observed: memActObserved.trim() }
    } else if (memActKind === 'skip_line') {
      payload = { action: 'skip_line', offset: Math.max(0, Number.parseInt(memActOffset, 10) || 0) }
    } else {
      payload = {
        action: 'skip_item',
        target: {
          kind: 'unreadable_unit',
          turn_log: memActObserved.trim(),
          line: Math.max(0, Number.parseInt(memActOffset, 10) || 0),
        },
      }
    }
    const res = await postKeeperMemoryAct(keeperName, payload)
    if (!res.ok) {
      setMemActStatus(`오류: ${res.error.message}`)
      return
    }
    setMemActStatus(`memory/act (${memActKind}) 적용 완료`)
    void loadMemory()
  }

  const handleDryRunConfigDiff = async () => {
    if (!cfgSchema || !cfgFieldKey) return
    const field = cfgSchema.categories.flatMap((c) => c.fields).find((f) => f.full_key === cfgFieldKey)
    if (!field) return
    setCfgError(null)
    let parsedValue: unknown = cfgFieldValue
    if (field.type === 'bool' || field.type === 'boolean') parsedValue = cfgFieldValue === 'true'
    else if (field.type === 'int' || field.type === 'integer') parsedValue = Number.parseInt(cfgFieldValue, 10)
    else if (field.type === 'float' || field.type === 'number') parsedValue = Number.parseFloat(cfgFieldValue)

    const res = await postConfigPatchApi({
      target: `keeper:${keeperName}`,
      expectedSha256: cfgSchema.file_sha256,
      dryRun: true,
      changes: [{ op: 'set', table: field.table, key: field.key, value: parsedValue }],
    })
    if (!res.ok) {
      setCfgError(res.error.message)
      return
    }
    setCfgDiff(res.value)
  }

  const cacheW = cacheSegs.total > 0 ? cacheSegs.total : 1
  const segReadW = (cacheSegs.cacheRead / cacheW) * 100
  const segCreateW = (cacheSegs.cacheCreate / cacheW) * 100
  const segUncachedW = (cacheSegs.uncachedInput / cacheW) * 100
  const segOutputW = (cacheSegs.output / cacheW) * 100

  return html`
    <aside class="kp-companion" aria-label="Debug Companion (⌘.)" data-companion-tab=${tab}>
      <div class="kp-companion-head">
        <span class="kp-roster-name">Debug Companion (⌘.)</span>
        <button type="button" class="btn-ghost" onClick=${props.onClose}>닫기</button>
      </div>

      <div class="kp-companion-tabs" role="tablist" aria-label="디버그 탭">
        ${([
          ['trace', 'Trace'],
          ['context', 'Context'],
          ['memory', 'Memory'],
          ['config-diff', 'Config Diff'],
        ] as const).map(([id, label]) => html`
          <button
            key=${id}
            type="button"
            role="tab"
            class="kp-companion-tab"
            aria-selected=${tab === id ? 'true' : 'false'}
            onClick=${() => setTab(id)}
          >
            ${label}
          </button>
        `)}
      </div>

      <div class="kp-companion-body">
        ${tab === 'trace' && html`
          ${traceError && html`<div class="ap-error">${traceError}</div>`}

          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Turn Gantt Waterfall (${turnRecords.length})</h3>
              <button type="button" class="btn-ghost" onClick=${() => void loadTrace()}>갱신</button>
            </div>
            ${turnRecords.length === 0
              ? html`<div class="kp-empty">턴 기록 없음</div>`
              : turnRecords.slice(0, 14).map((r) => {
                  const totalPct = Math.max(2, Math.min(100, Math.round(((r.request_latency_ms ?? 0) / maxLatencyMs) * 100)))
                  const ttfrcPct = Math.max(1, Math.min(totalPct, Math.round(((r.ttfrc_ms ?? 0) / maxLatencyMs) * 100)))
                  return html`
                    <div key=${r.turn_ref || r.absolute_turn} class="kp-kv-box">
                      <div class="kp-card-head">
                        <span class="kp-roster-name">#${r.absolute_turn} · ${r.turn_kind}</span>
                        <span class="kp-roster-sub tnum">
                          ${r.request_latency_ms != null ? `${Math.round(r.request_latency_ms)}ms` : '없음'}
                        </span>
                      </div>
                      <svg class="kp-svg-bar" viewBox="0 0 100 10" preserveAspectRatio="none" aria-label="턴 지연 바">
                        <rect x="0" y="0" width="100" height="10" class="kp-seg-bg" />
                        <rect x="0" y="1" width=${totalPct} height="8" class="kp-gantt-total" />
                        <rect x="0" y="1" width=${ttfrcPct} height="8" class="kp-gantt-ttfrc" />
                      </svg>
                    </div>
                  `
                })}
          </div>

          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Recent Tool Calls (${toolCalls?.count ?? 0})</h3>
            </div>
            ${!toolCalls || toolCalls.entries.length === 0
              ? html`<div class="kp-empty">도구 호출 없음</div>`
              : toolCalls.entries.slice(0, 15).map((tc, idx) => html`
                  <button
                    key=${tc.execution_id ?? idx}
                    type="button"
                    class="kp-kv-box"
                    onClick=${() => props.onInspect({
                      title: `Tool Call · ${tc.tool}`,
                      subtitle: `${keeperName} · ${Math.round(tc.duration_ms)}ms`,
                      kind: 'tool_call',
                      data: tc,
                    })}
                  >
                    <div class="kp-card-head">
                      <span class="kp-roster-name">${tc.tool}</span>
                      <span class="kp-pill" data-tone=${tc.disposition === 'failed' ? 'bad' : 'ok'}>
                        ${Math.round(tc.duration_ms)}ms
                      </span>
                    </div>
                    <span class="kp-roster-sub">${tc.wire_outcome}</span>
                  </button>
                `)}
          </div>

          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Raw Traces (${rawTraces.length})</h3>
            </div>
            ${rawTraces.length === 0
              ? html`<div class="kp-empty">Raw trace 파일 없음</div>`
              : rawTraces.slice(0, 8).map((rt) => html`
                  <button
                    key=${rt.file}
                    type="button"
                    class="btn-ghost"
                    onClick=${() => void handleOpenRawTrace(rt.file)}
                  >
                    ${rt.file} (${rt.records ?? '?'} rec · ${Math.round(rt.bytes / 1024)}KB)
                  </button>
                `)}
            ${rawTracePage && html`
              <div class="kp-roster-sub">최근 로드: ${String(rawTracePage.file ?? '')}</div>
            `}
          </div>
        `}

        ${tab === 'context' && html`
          <${UPlotChart}
            id=${`kp-ctx-${keeperName}`}
            title="60-Turn Context Fill %"
            subtitle=${html`
              <span class="kp-pill" data-tone="brass">
                Compaction epochs: ${compactionEpochs !== null ? compactionEpochs : '없음'}
              </span>
            `}
            data=${ctxChart.data}
            series=${CONTEXT_SERIES}
            height=${140}
            syncCrosshair=${false}
            emptyLabel="턴 컨텍스트 데이터 없음"
          />

          ${ctxChart.compactionTurns.length > 0 && html`
            <div class="kp-pill-row">
              <span class="kp-pill" data-tone="info">
                Compaction 감지 턴: ${ctxChart.compactionTurns.map((t) => `#${t}`).join(', ')}
              </span>
            </div>
          `}

          <!-- 4-segment Prompt Cache SVG stacked bar (zero inline style) -->
          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Prompt Cache (4-Segment)</h3>
              <span class="kp-pill" data-tone="ok">
                Hit ${cacheSegs.cacheHitPct !== null ? `${cacheSegs.cacheHitPct}%` : '없음'}
              </span>
            </div>
            <svg class="kp-svg-bar" viewBox="0 0 100 12" preserveAspectRatio="none" aria-label="프롬프트 캐시 4구간 막대">
              <rect x="0" y="0" width="100" height="12" class="kp-seg-bg" />
              <rect x="0" y="0" width=${segReadW} height="12" class="kp-seg-cache-read" />
              <rect x=${segReadW} y="0" width=${segCreateW} height="12" class="kp-seg-cache-create" />
              <rect x=${segReadW + segCreateW} y="0" width=${segUncachedW} height="12" class="kp-seg-uncached" />
              <rect x=${segReadW + segCreateW + segUncachedW} y="0" width=${segOutputW} height="12" class="kp-seg-output" />
            </svg>
            <div class="kp-grid-2">
              <div class="kp-kv-box">
                <span class="kp-kv-k">Cache Read</span>
                <span class="kp-kv-v">${cacheSegs.cacheRead.toLocaleString('en-US')}</span>
              </div>
              <div class="kp-kv-box">
                <span class="kp-kv-k">Cache Write</span>
                <span class="kp-kv-v">${cacheSegs.cacheCreate.toLocaleString('en-US')}</span>
              </div>
              <div class="kp-kv-box">
                <span class="kp-kv-k">Uncached In</span>
                <span class="kp-kv-v">${cacheSegs.uncachedInput.toLocaleString('en-US')}</span>
              </div>
              <div class="kp-kv-box">
                <span class="kp-kv-k">Output</span>
                <span class="kp-kv-v">${cacheSegs.output.toLocaleString('en-US')}</span>
              </div>
            </div>
          </div>

          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Last Prompt & Provider Input</h3>
            </div>
            ${lastPrompt
              ? html`
                  <div class="kp-roster-sub">
                    Turn #${lastPrompt.absolute_turn} · ${lastPrompt.assembled_bytes.toLocaleString('en-US')} bytes · ${lastPrompt.blocks.length} blocks
                  </div>
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${() => props.onInspect({
                      title: `Last Prompt #${lastPrompt.absolute_turn}`,
                      subtitle: keeperName,
                      kind: 'last_prompt',
                      data: lastPrompt,
                    })}
                  >
                    Last Prompt 전체 검사
                  </button>
                `
              : html`<div class="kp-empty">캡처된 프롬프트 없음</div>`}
            ${providerInput && html`
              <div class="kp-roster-sub">
                Provider Input: ${providerInput.wire.provider}/${providerInput.wire.model} (${providerInput.parts.length} parts · ${providerInput.wire.body_bytes.toLocaleString('en-US')} B)
              </div>
            `}
          </div>

          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Checkpoints / Clear / Reset</h3>
            </div>
            <div class="kp-roster-sub">
              Current: ${checkpoints?.current ? `${checkpoints.current.message_count} msgs (${checkpoints.current.snapshot_id.slice(0, 12)})` : checkpoints?.current_status ?? '없음'}
              · History: ${checkpoints?.history.length ?? 0}
            </div>
            ${contextStatus && html`<div class="kp-pill" data-tone="info">${contextStatus}</div>`}
            <div class="kp-lifecycle-bar">
              <button
                type="button"
                class="btn-ghost"
                onClick=${() => setPendingDanger((cur) => (cur === 'clear' ? null : 'clear'))}
              >
                Clear Context…
              </button>
              <button
                type="button"
                class="kp-btn-danger"
                onClick=${() => setPendingDanger((cur) => (cur === 'reset' ? null : 'reset'))}
              >
                Reset Keeper…
              </button>
            </div>
            ${pendingDanger !== null && html`
              <${TargetLockedAction}
                target=${{
                  workspaceId: activeWorkspaceId.value,
                  keeper: keeperName,
                  requestId: `${pendingDanger}:${keeperName}`,
                  revision: checkpoints?.current?.snapshot_id ?? checkpoints?.trace_id ?? 'none',
                }}
              >
                <button
                  type="button"
                  class="kp-btn-danger"
                  onClick=${async () => {
                    const action = pendingDanger
                    setPendingDanger(null)
                    if (action === 'clear') await handleClearHistory()
                    else await handleResetKeeper()
                  }}
                >
                  ${pendingDanger === 'clear' ? 'Clear Context 실행 확인' : 'Reset Keeper 실행 확인'}
                </button>
                <button type="button" class="btn-ghost" onClick=${() => setPendingDanger(null)}>
                  취소
                </button>
              <//>
            `}
          </div>
        `}

        ${tab === 'memory' && html`
          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Memory Facts Summary</h3>
              <button type="button" class="btn-ghost" onClick=${() => void loadMemory()}>갱신</button>
            </div>
            ${!memFacts
              ? html`<div class="kp-empty">불러오는 중…</div>`
              : html`
                  <div class="kp-grid-2">
                    <div class="kp-kv-box">
                      <span class="kp-kv-k">Ordinary Facts</span>
                      <span class="kp-kv-v">
                        ${memFacts.ordinary.state === 'present'
                          ? memFacts.ordinary.facts.length
                          : memFacts.ordinary.state === 'absent'
                            ? '없음'
                            : '오류'}
                      </span>
                    </div>
                    <div class="kp-kv-box">
                      <span class="kp-kv-k">Source-Bound</span>
                      <span class="kp-kv-v">
                        ${memFacts.source_bound.state === 'present'
                          ? memFacts.source_bound.facts.length
                          : memFacts.source_bound.state === 'absent'
                            ? '없음'
                            : '오류'}
                      </span>
                    </div>
                  </div>
                `}
            <div class="kp-roster-sub">
              Journal entries: ${memJournal?.returned ?? 0} · undecodable: ${memJournal?.undecodable_lines ?? 0}
            </div>
          </div>

          <div class="kp-card">
            <div class="kp-card-head">
              <h3>memory/act Recovery</h3>
            </div>
            <select
              class="kp-input"
              aria-label="memory/act 액션"
              value=${memActKind}
              onChange=${(e: Event) => setMemActKind((e.currentTarget as HTMLSelectElement).value as typeof memActKind)}
            >
              <option value="resume">resume</option>
              <option value="adopt">adopt (sha256)</option>
              <option value="restart_reading">restart_reading (turn_log id)</option>
              <option value="skip_line">skip_line (offset)</option>
              <option value="skip_item">skip_item (unreadable_unit)</option>
            </select>
            ${(memActKind === 'adopt' || memActKind === 'restart_reading' || memActKind === 'skip_item') && html`
              <input
                type="text"
                class="kp-input"
                placeholder=${memActKind === 'adopt' ? 'observed sha256 hex' : 'turn_log id'}
                value=${memActObserved}
                onInput=${(e: Event) => setMemActObserved((e.currentTarget as HTMLInputElement).value)}
              />
            `}
            ${(memActKind === 'skip_line' || memActKind === 'skip_item') && html`
              <input
                type="number"
                class="kp-input"
                placeholder="line offset"
                value=${memActOffset}
                onInput=${(e: Event) => setMemActOffset((e.currentTarget as HTMLInputElement).value)}
              />
            `}
            <button type="button" class="btn-primary" onClick=${() => void handleMemoryAct()}>
              memory/act 실행
            </button>
            ${memActStatus && html`<div class="kp-pill" data-tone="info">${memActStatus}</div>`}
          </div>
        `}

        ${tab === 'config-diff' && html`
          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Quick CAS Config Diff</h3>
              <span class="kp-pill">sha: ${cfgSchema?.file_sha256.slice(0, 8) || '없음'}</span>
            </div>
            ${cfgError && html`<div class="ap-error">${cfgError}</div>`}
            ${cfgSchema && html`
              <select
                class="kp-input"
                aria-label="설정 필드 선택"
                value=${cfgFieldKey}
                onChange=${(e: Event) => {
                  const nextKey = (e.currentTarget as HTMLSelectElement).value
                  setCfgFieldKey(nextKey)
                  const f = cfgSchema.categories.flatMap((c) => c.fields).find((x) => x.full_key === nextKey)
                  setCfgFieldValue(f ? String(f.current_value ?? '') : '')
                }}
              >
                ${cfgSchema.categories.flatMap((c) => c.fields).filter((f) => f.writable && !f.secret).map((f) => html`
                  <option key=${f.full_key} value=${f.full_key}>${f.full_key}</option>
                `)}
              </select>
              <input
                type="text"
                class="kp-input"
                aria-label="새 값"
                value=${cfgFieldValue}
                onInput=${(e: Event) => setCfgFieldValue((e.currentTarget as HTMLInputElement).value)}
              />
              <button type="button" class="btn-primary" onClick=${() => void handleDryRunConfigDiff()}>
                Dry-Run Diff 계산
              </button>
            `}
            ${cfgDiff && html`
              <div>
                <span class="kp-pill" data-tone="info">reload: ${cfgDiff.reload_scope}</span>
                <pre class="kp-diff">${cfgDiff.unified_diff || '(변경 없음)'}</pre>
              </div>
            `}
          </div>
        `}
      </div>
    </aside>
  `
}
