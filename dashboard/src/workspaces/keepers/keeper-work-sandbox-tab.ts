/**
 * Entity Tab 4: `Work & Sandbox` (`/keepers/:name/work-sandbox`)
 *
 * - Linked tasks assigned to this Keeper
 * - Virtualized paginated `tool-calls?limit=50` `<DataTable>` & `tool-stats`
 * - Operator-Note editor (`GET/POST /api/v1/keepers/:k/operator-note`)
 * - Keeper sandbox status (`GET /api/v1/infra/sandboxes/:k`, V2Envelope)
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'
import { DataTable, type DataTableColumn } from '../../components/primitives/data-table'
import {
  fetchKeeperLinkedTasksApi,
  fetchKeeperOperatorNoteApi,
  fetchKeeperSandboxApi,
  fetchKeeperToolCallsApi,
  fetchKeeperToolStatsApi,
  saveKeeperOperatorNoteApi,
} from './keepers-api'
import type {
  KeeperLinkedTask,
  KeeperOperatorNoteData,
  KeeperSandboxData,
  KeeperToolCallEntry,
  KeeperToolCallsData,
  KeeperToolStatsData,
  WorkspaceInspectPayload,
} from './types'

export interface KeeperWorkSandboxTabProps {
  readonly keeperName: string
  readonly onNavigate: (path: string) => void
  readonly onInspect: (payload: WorkspaceInspectPayload) => void
}

export function KeeperWorkSandboxTab(props: KeeperWorkSandboxTabProps) {
  const { keeperName } = props
  const [tasks, setTasks] = useState<readonly KeeperLinkedTask[]>([])
  const [toolCalls, setToolCalls] = useState<KeeperToolCallsData | null>(null)
  const [toolLimit, setToolLimit] = useState(50)
  const [toolStats, setToolStats] = useState<KeeperToolStatsData | null>(null)
  const [note, setNote] = useState<KeeperOperatorNoteData | null>(null)
  const [noteDraft, setNoteDraft] = useState('')
  const [noteSaving, setNoteSaving] = useState(false)
  const [noteFeedback, setNoteFeedback] = useState<string | null>(null)
  const [sandbox, setSandbox] = useState<KeeperSandboxData | null>(null)
  const [sandboxError, setSandboxError] = useState<string | null>(null)

  const loadAll = useCallback(async (limit = toolLimit) => {
    setSandboxError(null)
    const [tRes, tcRes, tsRes, nRes, sbRes] = await Promise.all([
      fetchKeeperLinkedTasksApi(keeperName),
      fetchKeeperToolCallsApi(keeperName, limit),
      fetchKeeperToolStatsApi(keeperName, 24),
      fetchKeeperOperatorNoteApi(keeperName),
      fetchKeeperSandboxApi(keeperName),
    ])
    if (tRes.ok) setTasks(tRes.value)
    if (tcRes.ok) setToolCalls(tcRes.value)
    if (tsRes.ok) setToolStats(tsRes.value)
    if (nRes.ok) {
      setNote(nRes.value)
      setNoteDraft(nRes.value.text)
    }
    if (sbRes.ok) {
      setSandbox(sbRes.value)
    } else {
      setSandbox(null)
      setSandboxError(sbRes.error.kind === 'not_found' ? '등록된 샌드박스 텔레메트리 없음' : sbRes.error.message)
    }
  }, [keeperName, toolLimit])

  useEffect(() => {
    void loadAll(toolLimit)
  }, [loadAll, toolLimit])

  const handleSaveNote = async () => {
    setNoteSaving(true)
    setNoteFeedback(null)
    const res = await saveKeeperOperatorNoteApi(keeperName, noteDraft)
    setNoteSaving(false)
    if (!res.ok) {
      setNoteFeedback(`저장 실패: ${res.error.message}`)
      return
    }
    setNote(res.value)
    setNoteFeedback('운영자 노트가 저장되었습니다 (다음 턴에 주입).')
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

  return html`
    <div class="kp-scroll-pane" data-keeper-tab="work-sandbox">
      <div class="kp-grid-2">
        <!-- Linked Tasks -->
        <section class="kp-card" aria-label="연결된 작업">
          <div class="kp-card-head">
            <h3>Linked Tasks (${tasks.length})</h3>
            <button type="button" class="btn-ghost" onClick=${() => props.onNavigate('/work/tasks')}>
              Tasks →
            </button>
          </div>
          ${tasks.length === 0
            ? html`<div class="kp-empty">담당 중인 Task 없음</div>`
            : tasks.map((t) => html`
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
            <button type="button" class="btn-ghost" onClick=${() => props.onNavigate('/infra/sandboxes')}>
              Infra →
            </button>
          </div>
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
              `
            : html`<div class="kp-empty">${sandboxError ?? '샌드박스 정보 없음'}</div>`}
        </section>
      </div>

      <!-- Operator-Note Editor -->
      <section class="kp-card" aria-label="운영자 노트 편집기">
        <div class="kp-card-head">
          <h3>Operator Note</h3>
          <div class="kp-pill-row">
            <span class="kp-pill" data-tone=${note?.pending ? 'brass' : 'default'}>
              ${note?.pending ? 'Pending (다음 턴 주입 대기)' : note?.consumed_turn != null ? `Consumed @ turn #${note.consumed_turn}` : '비어 있음'}
            </span>
            <span class="kp-pill">${noteBytes} B</span>
          </div>
        </div>
        <textarea
          class="kp-textarea"
          rows=${3}
          aria-label="운영자 노트 입력"
          placeholder="다음 턴 시작 시 Keeper에게 전달할 운영자 지시를 작성하세요…"
          value=${noteDraft}
          onInput=${(e: Event) => setNoteDraft((e.currentTarget as HTMLTextAreaElement).value)}
        />
        <div class="kp-lifecycle-bar">
          <button type="button" class="btn-primary" disabled=${noteSaving} onClick=${() => void handleSaveNote()}>
            ${noteSaving ? '저장 중…' : '운영자 노트 저장'}
          </button>
          ${noteFeedback && html`<span class="kp-pill" data-tone="info">${noteFeedback}</span>`}
        </div>
      </section>

      <!-- Tool Stats 24h Summary -->
      <section class="kp-card" aria-label="도구 호출 통계">
        <div class="kp-card-head">
          <h3>Tool Stats (24h · ${toolStats?.total_entries ?? 0} calls)</h3>
        </div>
        ${!toolStats || toolStats.tools.length === 0
          ? html`<div class="kp-empty">24h 도구 통계 없음</div>`
          : html`
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
          <h3>Tool Calls (${toolCalls?.count ?? 0})</h3>
          <div class="kp-pill-row">
            <button
              type="button"
              class="btn-ghost"
              disabled=${toolLimit >= 200}
              onClick=${() => setToolLimit((n) => Math.min(200, n + 50))}
            >
              더 불러오기 (+50)
            </button>
          </div>
        </div>
        <${DataTable}
          data=${toolCalls?.entries ?? []}
          columns=${toolCallColumns}
          getRowId=${(r: KeeperToolCallEntry, idx: number) => r.execution_id ?? `${r.ts}-${idx}`}
          onRowClick=${(row: KeeperToolCallEntry) => props.onInspect({
            title: `Tool Call · ${row.tool}`,
            subtitle: `${keeperName} · ${Math.round(row.duration_ms)}ms`,
            kind: 'tool_call',
            data: row,
          })}
          maxHeight=${320}
          virtualizeThreshold=${30}
          emptyLabel="도구 호출 기록 없음"
          caption="Keeper Tool Calls"
        />
      </section>
    </div>
  `
}
