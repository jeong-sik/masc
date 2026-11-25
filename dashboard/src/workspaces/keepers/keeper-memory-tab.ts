/**
 * Entity Tab 2: `Memory` (`/keepers/:name/memory`)
 *
 * - Full `/keepers/:k/memory-facts` (3-way discriminated `ordinary` & `source_bound` per #36)
 * - `/keepers/:k/memory-journal?activity=1&limit=50`
 * - `/keepers/:k/memory-os-internals` (compaction, canonical_turns, memory_digest, librarian_molt)
 * - `POST /keepers/:k/memory/act` recovery (`resume|adopt|restart_reading|skip_item|skip_line`)
 * - `POST /keepers/:k/memory/retractions` cleanup CRUD with TargetLockedAction safety
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { activeWorkspaceId } from '../../core/auth'
import { DataTable, type DataTableColumn } from '../../components/primitives/data-table'
import { TargetLockedAction } from '../../components/primitives/target-locked-action'
import {
  fetchKeeperMemoryFactsApi,
  fetchKeeperMemoryJournalApi,
  fetchKeeperMemoryOsInternalsApi,
  postKeeperMemoryAct,
  postKeeperMemoryRetractions,
} from './keepers-api'
import type {
  KeeperMemoryFactsData,
  KeeperMemoryJournalData,
  KeeperMemoryOsInternalsData,
  MemoryActPayload,
  OrdinaryMemoryFact,
  SourceBoundMemoryFact,
} from './types'

export interface KeeperMemoryTabProps {
  readonly keeperName: string
}

function summarizeMemoryValue(v: unknown): string | null {
  if (v === null || v === undefined) return null
  if (typeof v === 'string') return v.trim() || null
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  if (typeof v === 'object' && !Array.isArray(v)) {
    const rec = v as Record<string, unknown>
    const parts: string[] = []
    for (const key of ['state', 'kind', 'status', 'stop', 'reason', 'error']) {
      if (typeof rec[key] === 'string' && (rec[key] as string).trim()) {
        parts.push(`${key}=${(rec[key] as string).trim()}`)
      }
    }
    if (parts.length > 0) return parts.join(' · ')
    const keys = Object.keys(rec)
    return keys.length > 0 ? `{${keys.slice(0, 3).join(', ')}}` : null
  }
  if (Array.isArray(v)) return v.length > 0 ? `${v.length}건` : null
  return null
}

export function KeeperMemoryTab(props: KeeperMemoryTabProps) {
  const { keeperName } = props
  const [facts, setFacts] = useState<KeeperMemoryFactsData | null>(null)
  const [internals, setInternals] = useState<KeeperMemoryOsInternalsData | null>(null)
  const [journal, setJournal] = useState<KeeperMemoryJournalData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [showAllJournal, setShowAllJournal] = useState(false)
  const [showAllActivity, setShowAllActivity] = useState(false)

  // memory/act controls
  const [actKind, setActKind] = useState<'resume' | 'adopt' | 'restart_reading' | 'skip_line' | 'skip_item'>('resume')
  const [actObserved, setActObserved] = useState('')
  const [actOffset, setActOffset] = useState('0')
  const [actFeedback, setActFeedback] = useState<string | null>(null)

  // memory/retractions cleanup controls
  const [retractId, setRetractId] = useState('')
  const [retractReason, setRetractReason] = useState('')
  const [retractFeedback, setRetractFeedback] = useState<string | null>(null)

  const loadSeqRef = useRef(0)
  const loadAbortRef = useRef<AbortController | null>(null)

  const loadAll = useCallback(async () => {
    loadAbortRef.current?.abort()
    const ctrl = new AbortController()
    loadAbortRef.current = ctrl
    const seq = ++loadSeqRef.current
    setLoading(true)
    setError(null)
    const [fRes, iRes, jRes] = await Promise.all([
      fetchKeeperMemoryFactsApi(keeperName, ctrl.signal),
      fetchKeeperMemoryOsInternalsApi(keeperName, ctrl.signal),
      fetchKeeperMemoryJournalApi(keeperName, 50, ctrl.signal),
    ])
    if (ctrl.signal.aborted || seq !== loadSeqRef.current) return
    setLoading(false)
    const errs: string[] = []
    if (fRes.ok) setFacts(fRes.value)
    else if (fRes.error.kind !== 'aborted' && fRes.error.kind !== 'epoch_stale') {
      errs.push(`memory-facts: ${fRes.error.message}`)
    }
    if (iRes.ok) setInternals(iRes.value)
    else if (iRes.error.kind !== 'aborted' && iRes.error.kind !== 'epoch_stale') {
      errs.push(`memory-os-internals: ${iRes.error.message}`)
    }
    if (jRes.ok) setJournal(jRes.value)
    else if (jRes.error.kind !== 'aborted' && jRes.error.kind !== 'epoch_stale') {
      errs.push(`memory-journal: ${jRes.error.message}`)
    }
    if (errs.length > 0) setError(errs.join(' · '))
  }, [keeperName])

  useEffect(() => {
    setFacts(null)
    setInternals(null)
    setJournal(null)
    setShowAllJournal(false)
    setShowAllActivity(false)
    setError(null)
    void loadAll()
    return () => {
      loadAbortRef.current?.abort()
    }
  }, [keeperName, loadAll])

  const filteredOrdinary = useMemo<readonly OrdinaryMemoryFact[]>(() => {
    if (!facts || facts.ordinary.state !== 'present') return []
    const q = search.trim().toLowerCase()
    if (!q) return facts.ordinary.facts
    return facts.ordinary.facts.filter(
      (f) => f.claim.toLowerCase().includes(q)
        || f.category.toLowerCase().includes(q)
        || f.memory_id.toLowerCase().includes(q),
    )
  }, [facts, search])

  const filteredSourceBound = useMemo<readonly SourceBoundMemoryFact[]>(() => {
    if (!facts || facts.source_bound.state !== 'present') return []
    const q = search.trim().toLowerCase()
    if (!q) return facts.source_bound.facts
    return facts.source_bound.facts.filter(
      (f) => f.claim.toLowerCase().includes(q) || f.path.toLowerCase().includes(q),
    )
  }, [facts, search])

  const ordinaryColumns = useMemo<readonly DataTableColumn<OrdinaryMemoryFact>[]>(() => [
    { id: 'category', header: 'Category', accessor: (r) => r.category, sortable: true },
    { id: 'claim', header: 'Claim', cell: (r) => html`<${MarkdownContent} text=${r.claim} />` },
    { id: 'memory_id', header: 'ID', accessor: (r) => r.memory_id },
    {
      id: 'act',
      header: 'Cleanup',
      cell: (r) => html`
        <button
          type="button"
          class="btn-ghost"
          onClick=${() => {
            setRetractId(r.memory_id)
            if (!retractReason) setRetractReason('operator_cleanup')
          }}
        >
          Retract 선택
        </button>
      `,
    },
  ], [retractReason])

  const sourceBoundColumns = useMemo<readonly DataTableColumn<SourceBoundMemoryFact>[]>(() => [
    { id: 'path', header: 'Source Path', accessor: (r) => r.path, sortable: true },
    { id: 'claim', header: 'Claim', cell: (r) => html`<${MarkdownContent} text=${r.claim} />` },
    { id: 'sha', header: 'SHA256', accessor: (r) => r.sha256.slice(0, 12) },
  ], [])

  const handleRunAct = async () => {
    setActFeedback(null)
    let payload: MemoryActPayload
    if (actKind === 'resume') {
      payload = { action: 'resume' }
    } else if (actKind === 'adopt') {
      payload = { action: 'adopt', observed: actObserved.trim() }
    } else if (actKind === 'restart_reading') {
      payload = { action: 'restart_reading', observed: actObserved.trim() }
    } else if (actKind === 'skip_line') {
      payload = { action: 'skip_line', offset: Math.max(0, Number.parseInt(actOffset, 10) || 0) }
    } else {
      payload = {
        action: 'skip_item',
        target: {
          kind: 'unreadable_unit',
          turn_log: actObserved.trim(),
          line: Math.max(0, Number.parseInt(actOffset, 10) || 0),
        },
      }
    }
    const res = await postKeeperMemoryAct(keeperName, payload)
    if (!res.ok) {
      setActFeedback(`실패: ${res.error.message}`)
      return
    }
    setActFeedback(`memory/act (${actKind}) 완료`)
    void loadAll()
  }

  const handleRetract = async () => {
    const id = retractId.trim()
    const reason = retractReason.trim()
    if (!id || !reason) {
      setRetractFeedback('memory_id와 사유를 모두 입력하세요.')
      return
    }
    setRetractFeedback(null)
    const res = await postKeeperMemoryRetractions(keeperName, [{ memory_id: id, reason }])
    if (!res.ok) {
      setRetractFeedback(`Retract 실패: ${res.error.message}`)
      return
    }
    setRetractFeedback(`Retract 완료: ${id}`)
    setRetractId('')
    void loadAll()
  }

  const revision = facts?.ordinary.state === 'present' ? facts.ordinary.revision : 0

  return html`
    <div class="kp-scroll-pane" data-keeper-tab="memory">
      <div class="kp-card-head">
        <h3>Memory OS · ${keeperName}</h3>
        <div class="kp-pill-row kp-mem-toolbar">
          <input
            type="search"
            class="kp-input kp-mem-search"
            placeholder="Claim / Category / Path 필터…"
            aria-label="메모리 검색"
            value=${search}
            onInput=${(e: Event) => setSearch((e.currentTarget as HTMLInputElement).value)}
          />
          <button type="button" class="btn-ghost" disabled=${loading} onClick=${() => void loadAll()}>
            새로고침
          </button>
        </div>
      </div>

      ${error && html`<div class="ap-error" role="alert">${error}</div>`}

      ${facts && (facts.events_read_error || facts.events_unreadable_lines > 0) && html`
        <div class="ap-error sev-warn" role="alert">
          ${facts.events_read_error
            ? `메모리 이벤트 로그 읽기 오류: ${facts.events_read_error}`
            : `메모리 이벤트 로그 해독 불가 줄 ${facts.events_unreadable_lines}건 감지`}
          ${facts.events_read_error && facts.events_unreadable_lines > 0
            ? ` (해독 불가 ${facts.events_unreadable_lines}줄)`
            : ''}
        </div>
      `}

      <!-- Memory OS Internals (4 Sections) -->
      ${internals && (() => {
        const writerStateLabel = summarizeMemoryValue(internals.librarian_molt.writer_state)
        const pendingMoltLabel = summarizeMemoryValue(internals.librarian_molt.pending_molt)
        return html`
          <section class="kp-grid-4" aria-label="Memory OS 내부 상태">
            <div class="kp-kv-box">
              <span class="kp-kv-k">Compaction</span>
              <span class="kp-kv-v">
                ${internals.compaction.read_error
                  ? '⚠ 읽기 오류'
                  : internals.compaction.present
                    ? `${internals.compaction.epoch_count} epochs`
                    : '없음'}
              </span>
              <span
                class=${internals.compaction.read_error ? 'kp-roster-sub kp-wrap-text' : 'kp-roster-sub'}
                title=${internals.compaction.read_error ?? `archived ${internals.compaction.archived_turns_count} · verified ${internals.compaction.verified_facts_count}`}
              >
                ${internals.compaction.read_error
                  ? internals.compaction.read_error
                  : `archived ${internals.compaction.archived_turns_count} · verified ${internals.compaction.verified_facts_count}`}
              </span>
            </div>
            <div class="kp-kv-box">
              <span class="kp-kv-k">Canonical Turns</span>
              <span class="kp-kv-v">
                ${internals.canonical_turns.read_error
                  ? '⚠ 읽기 오류'
                  : internals.canonical_turns.present
                    ? internals.canonical_turns.turn_count
                    : '없음'}
              </span>
              <span
                class=${internals.canonical_turns.read_error ? 'kp-roster-sub kp-wrap-text' : 'kp-roster-sub'}
                title=${internals.canonical_turns.read_error ?? `watermark ${internals.canonical_turns.compaction_watermark_seq ?? '없음'} · resets ${internals.canonical_turns.history_resets_count}`}
              >
                ${internals.canonical_turns.read_error
                  ? internals.canonical_turns.read_error
                  : `watermark ${internals.canonical_turns.compaction_watermark_seq ?? '없음'} · resets ${internals.canonical_turns.history_resets_count}`}
              </span>
            </div>
            <div class="kp-kv-box">
              <span class="kp-kv-k">Memory Digest</span>
              <span class="kp-kv-v">${internals.memory_digest.present ? `${internals.memory_digest.fact_count} facts` : '없음'}</span>
              <span class="kp-roster-sub">
                rev ${internals.memory_digest.revision ?? '없음'} · ${internals.memory_digest.bytes} B
              </span>
            </div>
            <div class="kp-kv-box">
              <span class="kp-kv-k">Librarian Molt</span>
              <span
                class="kp-kv-v"
                title=${`${internals.librarian_molt.writer_kind}${writerStateLabel ? ` · ${writerStateLabel}` : ''}`}
              >
                ${internals.librarian_molt.writer_kind}${writerStateLabel ? ` · ${writerStateLabel}` : ''}
              </span>
              <span
                class="kp-roster-sub kp-wrap-text"
                title=${`${pendingMoltLabel ? `대기 molt: ${pendingMoltLabel} · ` : ''}acts: ${internals.librarian_molt.available_acts.length > 0 ? internals.librarian_molt.available_acts.join(', ') : '없음'}`}
              >
                ${pendingMoltLabel ? `대기 molt: ${pendingMoltLabel} · ` : ''}acts: ${internals.librarian_molt.available_acts.length > 0 ? internals.librarian_molt.available_acts.join(', ') : '없음'}
              </span>
            </div>
          </section>
        `
      })()}

      <!-- Ordinary Memory Facts (3-way discriminated) -->
      <section class="kp-card" aria-label="Ordinary Memory Facts">
        <div class="kp-card-head">
          <h3>Ordinary Facts</h3>
          ${facts?.ordinary.state === 'present' && html`
            <span class="kp-pill" data-tone="ok">
              rev ${facts.ordinary.revision} · ${facts.ordinary.facts.length} facts
            </span>
          `}
        </div>
        ${!facts
          ? html`<div class="kp-empty">${loading ? '불러오는 중…' : error ? '조회 실패로 표시할 수 없습니다.' : '데이터 없음'}</div>`
          : facts.ordinary.state === 'absent'
            ? html`<div class="kp-empty" data-branch="absent">스냅샷 없음 (present: false)</div>`
            : facts.ordinary.state === 'read_error'
              ? html`<div class="ap-error" data-branch="read_error" role="alert">Ordinary 읽기 오류: ${facts.ordinary.read_error}</div>`
              : html`
                  <${DataTable}
                    data=${filteredOrdinary}
                    columns=${ordinaryColumns}
                    getRowId=${(r: OrdinaryMemoryFact, idx: number) => r.memory_id || String(idx)}
                    maxHeight=${280}
                    emptyLabel="Ordinary fact 없음"
                    caption="Keeper Ordinary Memory Facts"
                  />
                  ${facts.ordinary.support_invalidations.length > 0 && html`
                    <div class="ap-error sev-warn">
                      Support Invalidations: ${facts.ordinary.support_invalidations.length}건
                    </div>
                  `}
                `}
      </section>

      <!-- Source-Bound Memory Facts (3-way discriminated) -->
      <section class="kp-card" aria-label="Source-Bound Memory Facts">
        <div class="kp-card-head">
          <h3>Source-Bound Facts</h3>
          ${facts?.source_bound.state === 'present' && html`
            <span class="kp-pill" data-tone="info">
              rev ${facts.source_bound.revision} · ${facts.source_bound.facts.length} facts
            </span>
          `}
        </div>
        ${!facts
          ? html`<div class="kp-empty">${loading ? '불러오는 중…' : error ? '조회 실패로 표시할 수 없습니다.' : '데이터 없음'}</div>`
          : facts.source_bound.state === 'absent'
            ? html`<div class="kp-empty" data-branch="absent">Source-bound 스냅샷 없음 (present: false)</div>`
            : facts.source_bound.state === 'read_error'
              ? html`<div class="ap-error" data-branch="read_error" role="alert">Source-bound 읽기 오류: ${facts.source_bound.read_error}</div>`
              : html`
                  <${DataTable}
                    data=${filteredSourceBound}
                    columns=${sourceBoundColumns}
                    getRowId=${(r: SourceBoundMemoryFact, idx: number) => `${r.path}:${idx}`}
                    maxHeight=${220}
                    emptyLabel="Source-bound fact 없음"
                    caption="Keeper Source-Bound Memory Facts"
                  />
                  ${facts.source_bound.invalidations.length > 0 && html`
                    <div class="ap-error sev-warn">
                      Source Invalidations: ${facts.source_bound.invalidations.map((i) => `${i.source_path} (${i.reason})`).join(', ')}
                    </div>
                  `}
                `}
      </section>

      <!-- Memory Recovery (memory/act) & Retraction Cleanup (memory/retractions) -->
      <div class="kp-grid-2">
        <section class="kp-card" aria-label="Librarian memory/act 복구">
          <div class="kp-card-head">
            <h3>Librarian Recovery (POST /memory/act)</h3>
          </div>
          <select
            class="kp-input"
            aria-label="memory/act 선택"
            value=${actKind}
            onChange=${(e: Event) => setActKind((e.currentTarget as HTMLSelectElement).value as typeof actKind)}
          >
            <option value="resume">resume</option>
            <option value="adopt">adopt</option>
            <option value="restart_reading">restart_reading</option>
            <option value="skip_line">skip_line</option>
            <option value="skip_item">skip_item</option>
          </select>
          ${(actKind === 'adopt' || actKind === 'restart_reading' || actKind === 'skip_item') && html`
            <input
              type="text"
              class="kp-input"
              placeholder=${actKind === 'adopt' ? 'observed digest sha256' : 'turn_log id'}
              value=${actObserved}
              onInput=${(e: Event) => setActObserved((e.currentTarget as HTMLInputElement).value)}
            />
          `}
          ${(actKind === 'skip_line' || actKind === 'skip_item') && html`
            <input
              type="number"
              class="kp-input"
              placeholder="offset / line"
              value=${actOffset}
              onInput=${(e: Event) => setActOffset((e.currentTarget as HTMLInputElement).value)}
            />
          `}
          <button type="button" class="btn-primary" onClick=${() => void handleRunAct()}>
            memory/act 적용
          </button>
          ${actFeedback && html`<div class="kp-pill" data-tone="info">${actFeedback}</div>`}
        </section>

        <section class="kp-card" aria-label="Memory Retraction Cleanup">
          <div class="kp-card-head">
            <h3>Fact Retraction Cleanup</h3>
          </div>
          <${TargetLockedAction}
            target=${{
              workspaceId: activeWorkspaceId.value,
              keeper: keeperName,
              requestId: `memory-retract:${keeperName}`,
              revision,
            }}
          >
            <input
              type="text"
              class="kp-input"
              placeholder="memory_id"
              aria-label="철회할 memory_id"
              value=${retractId}
              onInput=${(e: Event) => setRetractId((e.currentTarget as HTMLInputElement).value)}
            />
            <input
              type="text"
              class="kp-input"
              placeholder="철회 사유 (필수)"
              aria-label="철회 사유"
              value=${retractReason}
              onInput=${(e: Event) => setRetractReason((e.currentTarget as HTMLInputElement).value)}
            />
            <button type="button" class="kp-btn-danger" onClick=${() => void handleRetract()}>
              Fact 철회 (POST /memory/retractions)
            </button>
          <//>
          ${retractFeedback && html`<div class="kp-pill" data-tone="info">${retractFeedback}</div>`}
        </section>
      </div>

      <!-- Memory Journal & Activity -->
      <section class="kp-card" aria-label="Memory Journal 및 활동 로그">
        <div class="kp-card-head">
          <h3>Memory Journal (${journal?.returned ?? 0})</h3>
          ${journal && journal.undecodable_lines > 0 && html`
            <span class="kp-pill" data-tone="warn">
              ⚠ undecodable ${journal.undecodable_lines}
            </span>
          `}
        </div>
        ${!journal
          ? html`<div class="kp-empty">${loading ? '메모리 저널 불러오는 중…' : error ? '메모리 저널 조회 실패' : '메모리 저널 기록 없음'}</div>`
          : journal.entries.length === 0
            ? html`<div class="kp-empty">메모리 저널 기록 없음</div>`
          : html`
              ${journal.entries.length > 12 && html`
                <div class="kp-card-head">
                  <span class="kp-roster-sub">
                    ${showAllJournal
                      ? `전체 ${journal.entries.length}건 표시`
                      : `상위 12건 표시 (전체 ${journal.entries.length}건)`}
                  </span>
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${() => setShowAllJournal((v) => !v)}
                  >
                    ${showAllJournal ? '12건만 보기' : `전체 ${journal.entries.length}건 보기`}
                  </button>
                </div>
              `}
              <div class="kp-grid-2">
                ${(showAllJournal ? journal.entries : journal.entries.slice(0, 12)).map((entry, idx) => html`
                  <div key=${entry.structural_id || idx} class="kp-kv-box">
                    <div class="kp-card-head">
                      <span class="kp-roster-name">
                        ${entry.ok ? `rev ${entry.revision ?? '?'} · ${entry.source_kind ?? 'commit'}` : '저널 오류'}
                      </span>
                      <span class="kp-pill" data-tone=${entry.ok ? 'ok' : 'bad'}>
                        ${entry.ok ? `+${entry.added ?? 0} / -${entry.removed ?? 0}` : 'error'}
                      </span>
                    </div>
                    <span
                      class=${entry.ok ? 'kp-roster-sub' : 'kp-roster-sub kp-wrap-text'}
                      title=${entry.ok ? `retained ${entry.retained ?? 0} · invalidated ${entry.invalidated ?? 0}` : (entry.error ?? undefined)}
                    >
                      ${entry.ok ? `retained ${entry.retained ?? 0} · invalidated ${entry.invalidated ?? 0}` : entry.error}
                    </span>
                  </div>
                `)}
              </div>
            `}
        ${journal?.activity && journal.activity.events.length > 0 && html`
          <div>
            <div class="kp-card-head">
              <span class="kp-kv-k">
                Recent Activity Events (${showAllActivity ? journal.activity.events.length : Math.min(10, journal.activity.events.length)} / ${journal.activity.events.length})
              </span>
              ${journal.activity.events.length > 10 && html`
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => setShowAllActivity((v) => !v)}
                >
                  ${showAllActivity ? '접기' : '전체 보기'}
                </button>
              `}
            </div>
            <div class="kp-pill-row">
              ${(showAllActivity ? journal.activity.events : journal.activity.events.slice(0, 10)).map((ev, i) => html`
                <span key=${i} class="kp-pill" data-tone="info">
                  ${ev.kind} · r${ev.revision}
                </span>
              `)}
            </div>
          </div>
        `}
      </section>
    </div>
  `
}
