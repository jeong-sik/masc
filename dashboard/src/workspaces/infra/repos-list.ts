/**
 * Infra > Repos: the repository table and the add form.
 */

import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { apiMutate, authSession, currentSessionEpoch, isEpochCurrent, type Observed } from '../../core'
import { formatTimestampKo } from '../../lib/format-time'
import { DataTable, type DataTableColumn } from '../../components/primitives'
import {
  REPO_STATUS_RANK,
  formatSpan,
  lastSyncFact,
  repoStatusLabel,
  syncStall,
  type RepoSyncClock,
} from './repos-model'
import type { PullsSnapshot } from './repos-pulls-model'
import { PullAttention } from './repos-pulls'
import { canAdminRepos } from './repos-reads'
import { Chip, StateWord, useNowSec } from './repos-sections'
import type { InfraRepository } from './types'

const NEW_REPO_SYNC_INTERVAL_S = 300
const TABLE_SCROLL_AFTER = 8
const TABLE_SCROLL_HEIGHT = 340

/** The status word. A sync still "in progress" past the repository's own
 *  interval reads as a warning instead of ordinary progress. */
export function RepoStateWord(props: { readonly repo: RepoSyncClock }) {
  const nowSec = useNowSec()
  const label = repoStatusLabel(props.repo.status)
  const stalled = syncStall(props.repo, nowSec) !== null
  return html`<${StateWord} fact=${stalled ? { text: label.text, tone: 'warn' } : label} />`
}

function LastSync(props: { readonly repo: RepoSyncClock }) {
  const fact = lastSyncFact(props.repo, useNowSec())
  const at = props.repo.updated_at
  return html`
    <span class="rp-toned rp-nowrap" data-tone=${fact.tone} title=${at !== null ? formatTimestampKo(at) : undefined}>
      ${fact.text}
    </span>
  `
}

/** Says why a sync that never finished will not restart by itself, and what
 *  does. A session with no Sync button is told who has one. */
export function StalledNotice(props: { readonly repo: RepoSyncClock; readonly canSync: boolean }) {
  const stall = syncStall(props.repo, useNowSec())
  if (stall === null) return null
  return html`
    <div class="rp-notice" data-tone="warn" role="status">
      ${formatSpan(stall.intervalSec)}마다 동기화하는 저장소인데 ${formatSpan(stall.ageSec)}째 가져오는 중입니다.
      가져오는 중인 저장소는 자동 동기화에서 빠집니다.
      ${props.canSync ? '동기화를 누르면 다시 가져옵니다.' : '관리자가 동기화하면 다시 가져옵니다.'}
    </div>
  `
}

/** Sort key of the open pull request column. A repository whose count is not
 *  known sorts below one that has none. */
const COUNT_NOT_KNOWN = -1

function openPullCount(pulls: Observed<PullsSnapshot>, repoId: string): number {
  if (pulls.kind !== 'value') return COUNT_NOT_KNOWN
  const entry = pulls.data.byRepo.get(repoId)
  return entry?.pulls.kind === 'read' ? entry.pulls.pulls.length : COUNT_NOT_KNOWN
}

function RepoPullsCell(props: { readonly pulls: Observed<PullsSnapshot>; readonly repoId: string }) {
  const { pulls } = props
  if (pulls.kind === 'loading') return html`<span class="rp-plain">확인 중…</span>`
  if (pulls.kind === 'failed') return html`<span class="rp-toned" data-tone="bad">조회 실패</span>`
  if (pulls.kind !== 'value') return html`<span class="rp-plain">미보고</span>`
  if (pulls.data.repositoriesError !== null) return html`<span class="rp-toned" data-tone="bad">조회 실패</span>`
  const entry = pulls.data.byRepo.get(props.repoId)
  if (!entry || entry.pulls.kind === 'not_read') return html`<span class="rp-plain">읽지 않음</span>`
  if (entry.pulls.kind === 'not_github') return html`<span class="rp-plain">GitHub 아님</span>`
  if (entry.pulls.kind === 'failed') return html`<${Chip} tone="bad">조회 실패<//>`
  return html`<${PullAttention} pulls=${entry.pulls.pulls} unreadable=${entry.pulls.unreadable} />`
}

export function RepoTable(props: {
  readonly repos: readonly InfraRepository[]
  readonly pulls: Observed<PullsSnapshot>
  readonly selectedId: string | null
  readonly onSelect: (repoId: string) => void
}) {
  const { pulls, selectedId, onSelect } = props
  const columns = useMemo<readonly DataTableColumn<InfraRepository>[]>(() => [
    {
      id: 'name',
      header: '저장소',
      sortable: true,
      sortValue: (repo) => repo.name.toLowerCase(),
      // The row is clickable but not focusable, so the name is the keyboard
      // target. Its click stays here, or the row would select a second time.
      cell: (repo) => html`
        <button
          type="button"
          class="rp-repo-btn"
          aria-pressed=${repo.id === selectedId}
          onClick=${(event: Event) => {
            event.stopPropagation()
            onSelect(repo.id)
          }}
        >
          ${repo.name}
        </button>
      `,
    },
    {
      id: 'status',
      header: '상태',
      sortable: true,
      sortValue: (repo) => REPO_STATUS_RANK[repo.status.kind],
      cell: (repo) => html`
        <span class="rp-chips">
          <${RepoStateWord} repo=${repo} />
          ${repo.auto_sync === false && html`<${Chip}>자동 동기화 꺼짐<//>`}
        </span>
      `,
    },
    {
      id: 'synced',
      header: '마지막 동기화',
      sortable: true,
      sortValue: (repo) => repo.updated_at ?? 0,
      cell: (repo) => html`<${LastSync} repo=${repo} />`,
    },
    {
      id: 'pulls',
      header: '열린 PR',
      sortable: true,
      sortValue: (repo) => openPullCount(pulls, repo.id),
      cell: (repo) => html`<${RepoPullsCell} pulls=${pulls} repoId=${repo.id} />`,
    },
  ], [pulls, selectedId, onSelect])

  return html`
    <${DataTable}
      data=${props.repos}
      columns=${columns}
      getRowId=${(repo: InfraRepository) => repo.id}
      selectedRowId=${selectedId}
      onRowClick=${(repo: InfraRepository) => onSelect(repo.id)}
      initialSort=${{ id: 'name' }}
      maxHeight=${props.repos.length > TABLE_SCROLL_AFTER ? TABLE_SCROLL_HEIGHT : undefined}
      caption="등록된 저장소"
      className="rp-repos"
    />
  `
}

export function RepoAddForm(props: { readonly onAdded: (name: string) => void }) {
  const [name, setName] = useState('')
  const [url, setUrl] = useState('')
  const [branch, setBranch] = useState('main')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const mountedRef = useRef(true)
  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  const busyRef = useRef(false)

  const submit = async (ev: Event) => {
    ev.preventDefault()
    if (busyRef.current || !canAdminRepos(authSession.peek())) return
    const repoName = name.trim()
    const repoUrl = url.trim()
    // `required` lets a field of spaces through.
    if (!repoName || !repoUrl) {
      setError('이름과 Git URL(또는 로컬 경로)을 입력해 주세요.')
      return
    }
    const startEpoch = currentSessionEpoch()
    busyRef.current = true
    setBusy(true)
    setError(null)
    try {
      const res = await apiMutate<unknown>('POST', '/api/v1/repositories', {
        name: repoName,
        url: repoUrl,
        default_branch: branch.trim() || 'main',
        auto_sync: true,
        sync_interval: NEW_REPO_SYNC_INTERVAL_S,
      })
      if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
      if (!res.ok) {
        setError(`저장소 등록 실패: ${res.error.message}`)
        return
      }
      props.onAdded(repoName)
    } finally {
      busyRef.current = false
      if (mountedRef.current) setBusy(false)
    }
  }

  const field = (label: string, placeholder: string, value: string, set: (next: string) => void, required: boolean) => html`
    <label class="rp-field">
      <span>${label}</span>
      <input
        type="text"
        placeholder=${placeholder}
        value=${value}
        required=${required}
        disabled=${busy}
        onInput=${(e: Event) => set((e.target as HTMLInputElement).value)}
      />
    </label>
  `

  return html`
    <form class="rp-form" onSubmit=${submit}>
      ${field('이름', 'masc', name, setName, true)}
      ${field('Git URL 또는 로컬 경로', 'https://github.com/owner/repo.git', url, setUrl, true)}
      ${field('기본 브랜치', 'main', branch, setBranch, false)}
      <button type="submit" class="btn-primary" disabled=${busy}>${busy ? '등록 중…' : '등록'}</button>
      ${error !== null && html`<div class="rp-notice rp-form-wide" data-tone="bad" role="alert">${error}</div>`}
    </form>
  `
}
