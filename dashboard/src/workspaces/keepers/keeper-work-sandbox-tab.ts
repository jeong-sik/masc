/**
 * Entity Tab 4: `Work & Sandbox` (`/keepers/:name/work-sandbox`)
 *
 * - Linked tasks assigned to this Keeper
 * - Virtualized paginated `tool-calls?limit=50` `<DataTable>` & `tool-stats`
 * - Operator-Note editor (`GET/POST /api/v1/keepers/:k/operator-note`)
 * - Keeper sandbox status (`GET /api/v1/infra/sandboxes/:k`, V2Envelope)
 */

import type { WorkspaceInspectPayload } from '../types'
import { html } from 'htm/preact'
import { Fragment } from 'preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { InlineSpinner } from '../../components/common/inline-spinner'
import { DataTable, type DataTableColumn } from '../../components/primitives/data-table'
import { authSession, currentSessionEpoch, isEpochCurrent, sessionEpoch } from '../../core/auth'
import { isAdminLockedForSession } from '../../routes/router'
import { KeeperReadNotice, useKeeperRead } from './keeper-read'
import { KeeperToolCallInspector } from './keeper-tool-call-inspector'
import {
  fetchKeeperLinkedTasksApi,
  fetchKeeperOperatorNoteApi,
  fetchKeeperSandboxApi,
  fetchKeeperToolCallsApi,
  fetchKeeperToolStatsApi,
  saveKeeperOperatorNoteApi,
} from './keepers-api'
import type { KeeperRetainedProjection, KeeperToolCallEntry, KeeperToolSource } from './types'

export interface KeeperWorkSandboxTabProps {
  readonly keeperName: string
  readonly onNavigate: (path: string) => void
  readonly onInspect: (payload: WorkspaceInspectPayload) => void
}

export function KeeperWorkSandboxTab(props: KeeperWorkSandboxTabProps) {
  return html`<${KeeperWorkSandboxView} key=${JSON.stringify([sessionEpoch.value, props.keeperName])} ...${props} />`
}

function observedCount(received: boolean, count: number | undefined, limited: boolean): string | number {
  if (!received || count === undefined) return '—'
  if (!limited) return count
  return count > 0 ? `관측 ${count}` : '—'
}

function RetainedNotice({ observation }: { observation?: KeeperRetainedProjection | null }) {
  if (!observation) return null
  return html`<p class="kp-roster-sub" role="status">
    ${['마지막 성공 조회 표시 중', observation.lastSuccessAt, observation.reason].filter(Boolean).join(' · ')}
  </p>`
}

function toolSourceWarning(source: KeeperToolSource | null): string | null {
  if (!source) return null
  if (source.health === 'coverage_gap') {
    const reason = source.stale_reason ?? source.coverage_gaps?.at(-1)?.stale_reason
    return ['도구 기록 수집에 공백이 있습니다.', reason].filter(Boolean).join(' · ')
  }
  if (source.health === 'stale') return ['마지막 도구 기록이 오래되었습니다.', source.stale_reason].filter(Boolean).join(' · ')
  return null
}

function KeeperWorkSandboxView(props: KeeperWorkSandboxTabProps) {
  const { keeperName } = props
  const tasksRead = useKeeperRead(useCallback(
    (signal: AbortSignal) => fetchKeeperLinkedTasksApi(keeperName, signal), [keeperName],
  ))
  const sandboxRead = useKeeperRead(useCallback(
    (signal: AbortSignal) => fetchKeeperSandboxApi(keeperName, signal), [keeperName],
  ))
  const { data: tasks } = tasksRead
  const { data: sandbox } = sandboxRead
  const scope = tasks?.workspaceScope
  const sampled = scope != null && scope.shown < scope.total
  const limited = sampled || tasks?.retained != null
  const adminLocked = isAdminLockedForSession('admin', authSession.value)

  return html`
    <div class="kp-scroll-pane" data-keeper-tab="work-sandbox">
      <div class="kp-grid-2">
        <!-- Linked Tasks -->
        <section class="kp-card" aria-label="연결된 작업">
          <div class="kp-card-head">
            <h3>Linked Tasks (${observedCount(tasksRead.received, tasks?.tasks.length, limited)})</h3>
            <button type="button" class="btn-ghost" onClick=${() => props.onNavigate('/work/tasks')}>
              Tasks →
            </button>
          </div>
          <${KeeperReadNotice} label="연결 작업" read=${tasksRead} />
          <${RetainedNotice} observation=${tasks?.retained} />
          ${sampled && html`<p class="kp-roster-sub">작업공간 전체 ${scope.total}건 중 ${scope.shown}건 조회</p>`}
          ${tasksRead.received && tasks?.tasks.length === 0 && html`<div class="kp-empty">
            ${limited ? '이 조회 결과에서 담당 작업을 찾지 못했습니다.' : '조회된 담당 작업 없음'}
          </div>`}
          ${tasks?.tasks.map((t) => html`
                <div key=${t.id} class="kp-kv-box">
                  <div class="kp-card-head">
                    <span class="kp-roster-name">${t.title}</span>
                    <span class="kp-pill" data-tone=${t.status === 'Done' ? 'ok' : t.status === 'AwaitingVerification' ? 'warn' : 'info'}>
                      ${t.status}
                    </span>
                  </div>
                  <span class="kp-roster-sub">${t.id}${t.goal_id ? ` · goal ${t.goal_id}` : ''}</span>
                </div>
              `)}
        </section>

        <!-- Keeper Sandbox Status -->
        <section class="kp-card" aria-label="Keeper 샌드박스 상태">
          <div class="kp-card-head">
            <h3>Sandbox Status</h3>
            ${!adminLocked && html`
              <div class="kp-pill-row">
                <button
                  type="button"
                  class="btn-ghost"
                  data-testid="keeper-sandbox-config-btn"
                  onClick=${() => props.onNavigate(`/keepers/${encodeURIComponent(keeperName)}/config?section=sandbox`)}
                >
                  샌드박스 설정 →
                </button>
                <button
                  type="button"
                  class="btn-ghost"
                  data-testid="keeper-sandbox-infra-btn"
                  onClick=${() => props.onNavigate('/infra/sandboxes')}
                >
                  Infra →
                </button>
              </div>
            `}
          </div>
          <${KeeperReadNotice} label="샌드박스" read=${sandboxRead} />
          ${sandbox
            ? html`
                <div class="kp-grid-2">
                  <div class="kp-kv-box">
                    <span class="kp-kv-k">Backend</span>
                    <span class="kp-kv-v">${sandbox.backend}</span>
                  </div>
                  <div class="kp-kv-box">
                    <span class="kp-kv-k">Probe State</span>
                    <span class="kp-kv-v">${sandbox.probe_kind}</span>
                  </div>
                </div>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => props.onInspect({
                    title: `Sandbox · ${keeperName}`,
                    subtitle: sandbox.backend,
                    kind: 'sandbox',
                    data: sandbox.summary,
                  })}
                >
                  샌드박스 원시 상태 보기
                </button>
                ${sandboxRead.received && html`<button
                  type="button" class="btn-ghost"
                  onClick=${() => void sandboxRead.refresh()}
                >샌드박스 다시 읽기</button>`}
              `
            : sandboxRead.received && html`<div class="kp-lifecycle-bar">
                <span>현재 조회에서 샌드박스 텔레메트리 행을 찾지 못했습니다.</span>
                <button type="button" class="btn-ghost" onClick=${() => void sandboxRead.refresh()}>샌드박스 다시 읽기</button>
              </div>`}
        </section>
      </div>

      ${authSession.value.kind === 'single_user_local'
        ? html`<${KeeperLocalWork} keeperName=${keeperName} onInspect=${props.onInspect} />`
        : html`<p class="kp-card">운영자 노트와 도구 호출 통계·내역은 단일 계정 모드에서 사용할 수 있습니다.</p>`}
    </div>
  `
}

function KeeperLocalWork(props: Pick<KeeperWorkSandboxTabProps, 'keeperName' | 'onInspect'>) {
  const { keeperName } = props
  const [toolLimit, setToolLimit] = useState(50)
  const noteRead = useKeeperRead(useCallback(
    (signal: AbortSignal) => fetchKeeperOperatorNoteApi(keeperName, signal), [keeperName],
  ), true)
  const statsRead = useKeeperRead(useCallback(
    (signal: AbortSignal) => fetchKeeperToolStatsApi(keeperName, 24, signal), [keeperName],
  ))
  const callsRead = useKeeperRead(useCallback(
    (signal: AbortSignal) => fetchKeeperToolCallsApi(keeperName, toolLimit, signal), [keeperName, toolLimit],
  ))
  const { data: note } = noteRead
  const { data: toolStats } = statsRead
  const { data: toolCalls } = callsRead
  const [editedNote, setEditedNote] = useState<string | null>(null)
  const noteDraft = editedNote ?? note?.text ?? ''
  const [noteSaving, setNoteSaving] = useState(false)
  const [noteFeedback, setNoteFeedback] = useState<{ kind: 'saved' | 'failed'; text: string } | null>(null)
  const saving = useRef<AbortController | null>(null)
  useEffect(() => () => saving.current?.abort(), [])

  const handleSaveNote = async () => {
    if (authSession.peek().kind !== 'single_user_local' || saving.current || noteDraft.trim() === '') return
    const epoch = currentSessionEpoch()
    const controller = new AbortController()
    saving.current = controller
    setNoteSaving(true)
    setNoteFeedback(null)
    const result = await saveKeeperOperatorNoteApi(keeperName, noteDraft, controller.signal)
    if (controller.signal.aborted || !isEpochCurrent(epoch)) return
    saving.current = null
    setNoteSaving(false)
    if (!result.ok) {
      setNoteFeedback({ kind: 'failed', text: result.error.message })
      return
    }
    noteRead.accept(result.value)
    setEditedNote(current => current === noteDraft ? null : current)
    setNoteFeedback({ kind: 'saved', text: '운영자 노트 저장 완료' })
  }

  const toolCallColumns = useMemo<readonly DataTableColumn<KeeperToolCallEntry>[]>(() => [
    { id: 'tool', header: 'Tool', accessor: (r) => r.tool, sortable: true },
    { id: 'kind', header: 'Kind', accessor: (r) => r.record_kind },
    {
      id: 'outcome',
      header: 'Outcome',
      cell: (r) => html`
        <span class="kp-pill" data-tone=${r.disposition === 'failed' ? 'bad' : r.disposition === 'deferred' ? 'warn' : 'ok'}>
          ${r.disposition ?? r.wire_outcome}
        </span>
      `,
    },
    {
      id: 'duration',
      header: 'Duration (ms)',
      accessor: (r) => Math.round(r.duration_ms),
      numeric: true,
      sortable: true,
    },
    { id: 'turn', header: 'Turn', accessor: (r) => r.turn ?? null, numeric: true },
  ], [])

  const noteBytes = useMemo(() => new TextEncoder().encode(noteDraft).length, [noteDraft])

  const statsWarning = toolSourceWarning(toolStats)
  const callsWarning = toolSourceWarning(toolCalls)
  const statsLimited = statsWarning !== null || toolStats?.retained != null
  const callsLimited = callsWarning !== null || toolCalls?.retained != null

  return html`
    <${Fragment}>
      <!-- Operator-Note Editor -->
      <section class="kp-card" aria-label="운영자 노트 편집기">
        <div class="kp-card-head">
          <h3>Operator Note</h3>
          <div class="kp-pill-row">
            ${noteRead.received && html`
              <span class="kp-pill" data-tone=${note?.pending ? 'brass' : 'default'} role="status">
                ${note?.pending ? '다음 턴 주입 대기'
                  : note?.consumed_turn != null ? `Consumed @ turn #${note.consumed_turn}`
                  : note ? '저장된 노트' : '저장된 노트 없음'}
              </span>
            `}
            ${editedNote !== null && html`<span class="kp-pill" data-tone="warn">저장되지 않은 초안</span>`}
            <span class="kp-pill">${noteBytes} B</span>
          </div>
        </div>
        <${KeeperReadNotice} label="저장된 운영자 노트" read=${noteRead} />
        <textarea
          class="kp-textarea"
          rows=${3}
          aria-label="운영자 노트 입력"
          placeholder="다음 턴 시작 시 Keeper에게 전달할 운영자 지시를 작성하세요… (⌘↵ 저장)"
          value=${noteDraft}
          onInput=${(e: Event) => setEditedNote((e.currentTarget as HTMLTextAreaElement).value)}
          onKeyDown=${(e: KeyboardEvent) => {
            if (e.isComposing || e.keyCode === 229) return
            if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && !noteSaving) {
              e.preventDefault()
              void handleSaveNote()
            }
          }}
        />
        <div class="kp-lifecycle-bar">
          <button type="button" class="btn-primary" disabled=${noteSaving || noteDraft.trim() === ''} onClick=${() => void handleSaveNote()}>
            ${noteSaving ? html`<${InlineSpinner} size="xs" /> 저장 중…` : '운영자 노트 저장'}
          </button>
          ${noteSaving && html`<span class="sr-only" role="status">운영자 노트 저장 중…</span>`}
          ${noteFeedback?.kind === 'saved' && html`<span class="kp-pill" data-tone="ok" role="status">${noteFeedback.text}</span>`}
          ${noteFeedback?.kind === 'failed' && html`<span class="ap-error" role="alert">저장 실패 · ${noteFeedback.text}</span>`}
        </div>
      </section>

      <!-- Tool Stats 24h Summary -->
      <section class="kp-card" aria-label="도구 호출 통계">
        <div class="kp-card-head">
          <h3>Tool Stats (24h · ${observedCount(statsRead.received, toolStats?.total_entries, statsLimited)} calls)</h3>
        </div>
        <${KeeperReadNotice} label="도구 호출 통계" read=${statsRead} />
        <${RetainedNotice} observation=${toolStats?.retained} />
        ${statsWarning && html`<p class="kp-roster-sub" role="status">${statsWarning}</p>`}
        ${statsRead.received && !statsLimited && toolStats?.tools.length === 0 && html`<div class="kp-empty">24h 도구 통계 없음</div>`}
        ${toolStats && toolStats.tools.length > 0 && html`
              <div class="kp-grid-4">
                ${toolStats.tools.slice(0, 8).map((st) => html`
                  <div key=${st.name} class="kp-kv-box">
                    <span class="kp-kv-k">${st.name}</span>
                    <span class="kp-kv-v">${st.call_count} calls</span>
                    <span class="kp-roster-sub">
                      ok ${st.success_count} · fail ${st.failure_count} · p95 ${Math.round(st.p95_duration_ms)}ms
                    </span>
                  </div>
                `)}
              </div>
            `}
      </section>

      <!-- Paginated Virtualized Tool Calls -->
      <section class="kp-card" aria-label="도구 호출 내역">
        <div class="kp-card-head">
          <h3>Tool Calls (${observedCount(callsRead.received, toolCalls?.count, callsLimited)})</h3>
          <div class="kp-pill-row">
            <button
              type="button"
              class="btn-ghost"
              disabled=${!callsRead.received || toolLimit >= 200}
              onClick=${() => setToolLimit((n) => Math.min(200, n + 50))}
            >
              더 불러오기 (+50)
            </button>
          </div>
        </div>
        <${KeeperReadNotice} label="도구 호출 내역" read=${callsRead} />
        <${RetainedNotice} observation=${toolCalls?.retained} />
        ${callsWarning && html`<p class="kp-roster-sub" role="status">${callsWarning}</p>`}
        ${toolCalls && (toolCalls.entries.length > 0 || (callsRead.received && !callsLimited)) && html`
        <${DataTable}
          data=${toolCalls.entries}
          columns=${toolCallColumns}
          getRowId=${(r: KeeperToolCallEntry, idx: number) => r.execution_id ?? `${r.ts}-${idx}`}
          onRowClick=${(row: KeeperToolCallEntry) => props.onInspect({
            title: `Tool Call · ${row.tool}`,
            subtitle: `${keeperName} · ${Math.round(row.duration_ms)}ms`,
            kind: 'tool_call',
            data: row,
            render: () => html`
              <${KeeperToolCallInspector}
                key=${`${keeperName}:${row.execution_id ?? `${row.ts}-${row.tool}`}`}
                keeperName=${keeperName}
                entry=${row}
              />
            `,
          })}
          maxHeight=${320}
          virtualizeThreshold=${30}
          emptyLabel="도구 호출 기록 없음"
          caption="Keeper Tool Calls"
        />`}
      </section>
    <//>
  `
}
