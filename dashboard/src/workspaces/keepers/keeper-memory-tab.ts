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
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'
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

export function KeeperMemoryTab(props: KeeperMemoryTabProps) {
  const { keeperName } = props
  const [facts, setFacts] = useState<KeeperMemoryFactsData | null>(null)
  const [internals, setInternals] = useState<KeeperMemoryOsInternalsData | null>(null)
  const [journal, setJournal] = useState<KeeperMemoryJournalData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')

  // memory/act controls
  const [actKind, setActKind] = useState<'resume' | 'adopt' | 'restart_reading' | 'skip_line' | 'skip_item'>('resume')
  const [actObserved, setActObserved] = useState('')
  const [actOffset, setActOffset] = useState('0')
  const [actFeedback, setActFeedback] = useState<string | null>(null)

  // memory/retractions cleanup controls
  const [retractId, setRetractId] = useState('')
  const [retractReason, setRetractReason] = useState('')
  const [retractFeedback, setRetractFeedback] = useState<string | null>(null)

  const loadAll = useCallback(async () => {
    setLoading(true)
    setError(null)
    const [fRes, iRes, jRes] = await Promise.all([
      fetchKeeperMemoryFactsApi(keeperName),
      fetchKeeperMemoryOsInternalsApi(keeperName),
      fetchKeeperMemoryJournalApi(keeperName, 50),
    ])
    setLoading(false)
    if (fRes.ok) setFacts(fRes.value)
    else setError(fRes.error.message)
    if (iRes.ok) setInternals(iRes.value)
    if (jRes.ok) setJournal(jRes.value)
  }, [keeperName])

  useEffect(() => {
    void loadAll()
  }, [loadAll])

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
    { id: 'claim', header: 'Claim', accessor: (r) => r.claim },
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
    { id: 'claim', header: 'Claim', accessor: (r) => r.claim },
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
        <div class="kp-pill-row">
          <input
            type="search"
            class="kp-input"
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

      <!-- Memory OS Internals (4 Sections) -->
      ${internals && html`
        <section class="kp-grid-4" aria-label="Memory OS 내부 상태">
          <div class="kp-kv-box">
            <span class="kp-kv-k">Compaction</span>
            <span class="kp-kv-v">${internals.compaction.present ? `${internals.compaction.epoch_count} epochs` : '없음'}</span>
            <span class="kp-roster-sub">
              archived ${internals.compaction.archived_turns_count} · verified ${internals.compaction.verified_facts_count}
            </span>
          </div>
          <div class="kp-kv-box">
            <span class="kp-kv-k">Canonical Turns</span>
            <span class="kp-kv-v">${internals.canonical_turns.present ? internals.canonical_turns.turn_count : '없음'}</span>
            <span class="kp-roster-sub">
              watermark ${internals.canonical_turns.compaction_watermark_seq ?? '없음'} · resets ${internals.canonical_turns.history_resets_count}
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
            <span class="kp-kv-v">${internals.librarian_molt.writer_kind}</span>
            <span class="kp-roster-sub">
              acts: ${internals.librarian_molt.available_acts.length > 0 ? internals.librarian_molt.available_acts.join(', ') : '없음'}
            </span>
          </div>
        </section>
      `}

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
          ? html`<div class="kp-empty">불러오는 중…</div>`
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
          ? html`<div class="kp-empty">불러오는 중…</div>`
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
        ${!journal || journal.entries.length === 0
          ? html`<div class="kp-empty">메모리 저널 기록 없음</div>`
          : html`
              <div class="kp-grid-2">
                ${journal.entries.slice(0, 12).map((entry, idx) => html`
                  <div key=${entry.structural_id || idx} class="kp-kv-box">
                    <div class="kp-card-head">
                      <span class="kp-roster-name">
                        ${entry.ok ? `rev ${entry.revision ?? '?'} · ${entry.source_kind ?? 'commit'}` : '저널 오류'}
                      </span>
                      <span class="kp-pill" data-tone=${entry.ok ? 'ok' : 'bad'}>
                        ${entry.ok ? `+${entry.added ?? 0} / -${entry.removed ?? 0}` : 'error'}
                      </span>
                    </div>
                    <span class="kp-roster-sub">
                      ${entry.ok ? `retained ${entry.retained ?? 0} · invalidated ${entry.invalidated ?? 0}` : entry.error}
                    </span>
                  </div>
                `)}
              </div>
            `}
        ${journal?.activity && journal.activity.events.length > 0 && html`
          <div>
            <span class="kp-kv-k">Recent Activity Events (${journal.activity.events.length})</span>
            <div class="kp-pill-row">
              ${journal.activity.events.slice(0, 10).map((ev, i) => html`
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
