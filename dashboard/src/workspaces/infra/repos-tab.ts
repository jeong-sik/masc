/**
 * Infra L1 Tab 2: Repos & 24h Changes
 *
 * - GET/POST /api/v1/repositories (list, add, sync, remove).
 * - GET /api/v1/ide/repository-activity?repo_id=<id>&window_hours=24 (OkData envelope per #36 —
 *   ALWAYS supplies required repo_id!).
 * - Renders Keeper file-write diffs using the `diff` package with 1-click onInspect wide drawer ([⤢]),
 *   cleanly replacing the retired Web IDE!
 */

import { html } from 'htm/preact'
import { UnifiedDiffView } from '../../components/common/unified-diff'
import { pushShellToast } from '../../shell/shell-state'
import { createTwoFilesPatch } from 'diff'
import { useEffect, useRef, useState } from 'preact/hooks'
import {
  apiGet,
  apiMutate,
  apiRequest,
  authSession,
  currentSessionEpoch,
  isEpochCurrent,
  resourceCache,
  sessionEpoch,
} from '../../core'
import { MasterDetail } from '../../components/primitives'
import { KeeperBadge } from '../../components/keeper-badge'
import { isAdminLockedForSession } from '../../routes/router'
import {
  describeWireType,
  expectOptionalArrayField,
  expectOptionalRecordArrayField,
  expectRecordElements,
  expectRequiredStringField,
  expectWireRecord,
  isJsonRecord,
} from '../../lib/wire-decode'
import {
  extractChangeBeforeAfter,
  extractChangePath,
  formatUnixTs,
  type InfraRepository,
  type RepoActivityChange,
  type RepoActivityData,
  type WorkspaceViewProps,
} from './types'

function decodeRepoList(raw: unknown): readonly InfraRepository[] {
  const ctx = 'GET /api/v1/repositories'
  let rows: readonly unknown[]
  let field = 'repositories'
  if (Array.isArray(raw)) {
    rows = raw
  } else if (isJsonRecord(raw)) {
    if ('repositories' in raw && raw.repositories !== undefined) {
      rows = expectOptionalArrayField<unknown>(raw, 'repositories', ctx)
    } else if (raw.ok === true && 'data' in raw && raw.data !== undefined) {
      field = 'data'
      rows = expectOptionalArrayField<unknown>(raw, 'data', ctx)
    } else {
      rows = []
    }
  } else {
    throw new Error(`${ctx}: 배열 또는 객체 응답이 필요합니다 (${describeWireType(raw)} 수신).`)
  }
  const records = expectRecordElements<Record<string, unknown>>(rows, field, ctx)
  return records.map((r, idx) => {
    const rowCtx = `${ctx} ${field}[${idx}]`
    const id = expectRequiredStringField(r, 'id', rowCtx).trim()
    const name = expectRequiredStringField(r, 'name', rowCtx).trim()
    if (id === '' || name === '') {
      throw new Error(`${rowCtx}: "id"와 "name" 필드는 비어 있을 수 없습니다.`)
    }
    return {
      id,
      name,
      url: typeof r.url === 'string' ? r.url : '',
      codebase: typeof r.codebase === 'string' ? r.codebase : null,
      local_path: typeof r.local_path === 'string' ? r.local_path : '',
      default_branch: typeof r.default_branch === 'string' ? r.default_branch : 'main',
      status: typeof r.status === 'string' ? r.status : 'unknown',
      auto_sync: r.auto_sync === true,
      sync_interval: typeof r.sync_interval === 'number' ? r.sync_interval : 300,
    }
  })
}

function decodeRepoActivityData(raw: unknown): RepoActivityData {
  const ctx = 'GET /api/v1/ide/repository-activity'
  const rec = expectWireRecord(raw, ctx)
  const changes = expectOptionalRecordArrayField<RepoActivityChange>(rec, 'changes', ctx)
  return {
    ...(rec as unknown as RepoActivityData),
    repo_id: typeof rec.repo_id === 'string' ? rec.repo_id : '',
    window_hours: typeof rec.window_hours === 'number' ? rec.window_hours : 24,
    incomplete: typeof rec.incomplete === 'number' ? rec.incomplete : 0,
    unattributed: typeof rec.unattributed === 'number' ? rec.unattributed : 0,
    changes,
  }
}

export function buildUnifiedChangeDiff(change: RepoActivityChange): string {
  const filePath = extractChangePath(change.location)
  const { before, after, unified } = extractChangeBeforeAfter(change.change)
  if (unified) return unified
  return createTwoFilesPatch(`a/${filePath}`, `b/${filePath}`, before, after, 'before', 'after', { context: 3 })
}

function renderDiffLines(patchText: string, maxLines = 40) {
  return html`<${UnifiedDiffView} diffText=${patchText} maxLines=${maxLines} padding="var(--sp-2)" />`
}

export function ReposTab(props: WorkspaceViewProps) {
  const session = authSession.value
  const epoch = sessionEpoch.value
  const isSingleUser = session.kind === 'single_user_local'
  const canAdminRepos = isSingleUser && !isAdminLockedForSession('admin', session)

  const reposObs = resourceCache.observe<readonly InfraRepository[]>('infra:repositories').value
  const [selectedRepoId, setSelectedRepoId] = useState<string | null>(null)
  const [showAddForm, setShowAddForm] = useState(false)
  const [newName, setNewName] = useState('')
  const [newUrl, setNewUrl] = useState('')
  const [newBranch, setNewBranch] = useState('main')
  const [errorBanner, setErrorBanner] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  const repos = reposObs.kind === 'value' ? reposObs.data : []
  const effectiveRepoId = selectedRepoId && repos.some((r) => r.id === selectedRepoId)
    ? selectedRepoId
    : (repos[0]?.id ?? null)

  const activityKey = effectiveRepoId ? `infra:repo-activity:${effectiveRepoId}` : 'infra:repo-activity:none'
  const activityObs = resourceCache.observe<RepoActivityData>(activityKey).value

  const hasSingleUserAccess = (): boolean => authSession.peek().kind === 'single_user_local'
  const hasAdminRepoAccess = (): boolean => {
    const cur = authSession.peek()
    return cur.kind === 'single_user_local' && !isAdminLockedForSession('admin', cur)
  }

  const loadRepos = (reason: 'mount' | 'manual' = 'mount') => {
    if (!hasSingleUserAccess()) return
    void resourceCache.fetch<readonly InfraRepository[]>(
      'infra:repositories',
      (signal) => apiGet<readonly InfraRepository[]>('/api/v1/repositories', { signal, decode: decodeRepoList }),
      { ttlMs: 20_000, topics: ['repositories'], reason },
    )
  }

  const loadActivity = (repoId: string, reason: 'mount' | 'manual' = 'mount') => {
    if (!hasAdminRepoAccess()) return
    void resourceCache.fetch<RepoActivityData>(
      `infra:repo-activity:${repoId}`,
      (signal) => apiRequest<RepoActivityData>({
        method: 'GET',
        path: `/api/v1/ide/repository-activity?repo_id=${encodeURIComponent(repoId)}&window_hours=24`,
        envelope: 'ok_data',
        decode: decodeRepoActivityData,
        signal,
      }),
      { ttlMs: 20_000, topics: ['repository_activity'], reason },
    )
  }

  const mountedRef = useRef(true)
  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  useEffect(() => {
    if (!isSingleUser) return
    loadRepos('mount')
  }, [epoch, isSingleUser])

  useEffect(() => {
    if (!canAdminRepos) {
      setShowAddForm(false)
      return
    }
    if (effectiveRepoId) {
      loadActivity(effectiveRepoId, 'mount')
    }
  }, [effectiveRepoId, epoch, canAdminRepos])

  const handleAddRepo = async (ev: Event) => {
    ev.preventDefault()
    if (!hasAdminRepoAccess() || !newName.trim() || !newUrl.trim()) return
    const startEpoch = currentSessionEpoch()
    const trimmedName = newName.trim()
    setBusy('add')
    setErrorBanner(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/repositories', {
      name: trimmedName,
      url: newUrl.trim(),
      default_branch: newBranch.trim() || 'main',
      auto_sync: true,
      sync_interval: 300,
    })
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    setBusy(null)
    if (!res.ok) {
      setErrorBanner(`저장소 등록 실패: ${res.error.message}`)
      return
    }
    pushShellToast(`저장소 '${trimmedName}' 등록 완료.`, 'success')
    setNewName('')
    setNewUrl('')
    setShowAddForm(false)
    loadRepos('manual')
  }

  const handleSyncRepo = async (repoId: string) => {
    if (!hasAdminRepoAccess()) return
    const startEpoch = currentSessionEpoch()
    setBusy(`sync:${repoId}`)
    setErrorBanner(null)
    const res = await apiMutate<unknown>('POST', `/api/v1/repositories/${encodeURIComponent(repoId)}/sync`, {})
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    setBusy((cur) => (cur === `sync:${repoId}` ? null : cur))
    if (!res.ok) {
      setErrorBanner(`동기화 실패: ${res.error.message}`)
      return
    }
    pushShellToast(`${repoId} 동기화 완료.`, 'success')
    loadActivity(repoId, 'manual')
  }

  const handleInspectDiff = (change: RepoActivityChange) => {
    const filePath = extractChangePath(change.location)
    const patch = buildUnifiedChangeDiff(change)
    props.onInspect({
      title: filePath,
      subtitle: `${change.keeper} · ${formatUnixTs(change.at)}${change.task_id ? ` · ${change.task_id}` : ''}`,
      kind: 'repo_diff',
      data: change,
      render: () => html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', minWidth: 0 }}>
          <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
            <${KeeperBadge} id=${change.keeper} size="sm" />
            <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: change.succeeded ? 'var(--ok-fg)' : 'var(--err-fg)' }}>
              ${change.succeeded ? '적용 성공' : '실패'}
            </span>
            ${change.turn !== null && html`<span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>turn #${change.turn}</span>`}
          </div>
          ${renderDiffLines(patch, 500)}
        </div>
      `,
    })
  }

  const activityData = activityObs.kind === 'value' ? activityObs.data : null
  const activityChanges = activityData ? activityData.changes : []
  const selectedRepo = repos.find((r) => r.id === effectiveRepoId) ?? null

  const masterPane = html`
    <div style=${{ padding: 'var(--sp-3)', display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}>
      <div class="wka-h">
        <h3>등록된 저장소 (<span class="tnum">${repos.length}</span>)</h3>
        ${canAdminRepos && html`
          <button type="button" class="btn-primary" onClick=${() => setShowAddForm((v) => !v)}>
            ${showAddForm ? '취소' : '+ 저장소 추가'}
          </button>
        `}
      </div>

      ${canAdminRepos && showAddForm && html`
        <form onSubmit=${handleAddRepo} style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', padding: 'var(--sp-2)', background: 'var(--bg-2)', border: '1px solid var(--line-1)', borderRadius: 'var(--radius-sm)' }}>
          <input
            type="text"
            placeholder="이름 (예: masc)"
            value=${newName}
            onInput=${(e: Event) => setNewName((e.target as HTMLInputElement).value)}
            required
            style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
          />
          <input
            type="text"
            placeholder="Git URL 또는 로컬 경로"
            value=${newUrl}
            onInput=${(e: Event) => setNewUrl((e.target as HTMLInputElement).value)}
            required
            style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
          />
          <div style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
            <input
              type="text"
              placeholder="기본 브랜치 (main)"
              value=${newBranch}
              onInput=${(e: Event) => setNewBranch((e.target as HTMLInputElement).value)}
              style=${{ flex: 1, minWidth: 0, padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
            />
            <button type="submit" class="btn-primary" disabled=${busy === 'add'}>등록</button>
          </div>
        </form>
      `}

      ${reposObs.kind === 'loading' && html`<div class="dtable-absent">저장소 불러오는 중…</div>`}
      ${reposObs.kind === 'failed' && html`<div class="ap-error" role="alert">저장소 조회 실패: ${reposObs.error.message}</div>`}
      ${(reposObs.kind === 'absent' || reposObs.kind === 'unreported') && html`
        <div class="dtable-absent">저장소 목록을 확인할 수 없습니다.</div>
      `}
      ${reposObs.kind === 'value' && repos.length === 0 && html`
        <div class="dtable-absent">등록된 저장소가 없습니다.</div>
      `}
      ${repos.map((repo) => {
        const isSel = repo.id === effectiveRepoId
        return html`
          <div
            key=${repo.id}
            style=${{
              padding: 'var(--sp-2)',
              borderRadius: 'var(--radius-sm)',
              border: `1px solid ${isSel ? 'var(--line-3)' : 'var(--line-1)'}`,
              background: isSel ? 'var(--bg-4)' : 'var(--bg-2)',
              display: 'flex',
              flexDirection: 'column',
              gap: 'var(--sp-1)',
            }}
          >
            <div style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 'var(--sp-2)' }}>
              <button
                type="button"
                onClick=${() => setSelectedRepoId(repo.id)}
                style=${{ background: 'transparent', border: 'none', padding: 0, textAlign: 'left', cursor: 'pointer', fontWeight: 600, fontSize: 'var(--fs-13)', color: 'var(--fg-1)' }}
              >
                ${repo.name}
              </button>
              ${canAdminRepos && html`
                <button
                  type="button"
                  class="btn-ghost"
                  style=${{ padding: 'var(--sp-0) var(--sp-1)', fontSize: 'var(--fs-11)' }}
                  disabled=${busy === `sync:${repo.id}`}
                  onClick=${() => void handleSyncRepo(repo.id)}
                >
                  동기화
                </button>
              `}
            </div>
            <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
              ${repo.default_branch} · ${repo.status}
            </div>
          </div>
        `
      })}
    </div>
  `

  const detailPane = html`
    <div style=${{ padding: 'var(--sp-3)', display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', minWidth: 0 }}>
      <div class="wka-h">
        <h3>${selectedRepo ? `${selectedRepo.name} · 24시간 Keeper 파일 변경 Diff` : '24시간 파일 변경 내역'}</h3>
        ${canAdminRepos && selectedRepo && html`
          <button type="button" class="btn-ghost" onClick=${() => loadActivity(selectedRepo.id, 'manual')}>새로고침</button>
        `}
      </div>

      ${!canAdminRepos && html`
        <div class="wka-card dtable-absent" data-testid="infra-repo-activity-admin-locked" role="status">
          24시간 Keeper 파일 변경 이력(<span class="mono">/api/v1/ide/repository-activity</span>)과 저장소 등록·동기화는 관리자 전용입니다.
        </div>
      `}

      ${canAdminRepos && !selectedRepo && html`<div class="dtable-absent">왼쪽에서 저장소를 선택하세요.</div>`}

      ${canAdminRepos && selectedRepo && activityObs.kind === 'loading' && html`<div class="dtable-absent">24시간 파일 변경 이력 불러오는 중…</div>`}

      ${canAdminRepos && selectedRepo && activityObs.kind === 'failed' && html`
        <div class="ap-error" role="alert">변경 이력 조회 실패: ${activityObs.error.message}</div>
      `}

      ${canAdminRepos && selectedRepo && activityData && html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', minWidth: 0 }}>
          <div class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
            변경 ${activityChanges.length}건 · 미완결 ${activityData.incomplete ?? 0} · 미귀속 ${activityData.unattributed ?? 0} (window=${activityData.window_hours ?? 24}h)
          </div>

          ${activityChanges.length === 0
            ? html`<div class="dtable-absent">최근 24시간 동안 기록된 Keeper 파일 쓰기가 없습니다.</div>`
            : activityChanges.slice(0, 40).map((ch, idx) => {
                const filePath = extractChangePath(ch.location)
                const patch = buildUnifiedChangeDiff(ch)
                return html`
                  <article key=${`${ch.at}-${idx}`} class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', background: 'var(--bg-2)' }}>
                    <div style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
                      <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', minWidth: 0 }}>
                        <${KeeperBadge} id=${ch.keeper} size="sm" />
                        <span class="mono" style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-1)' }}>${filePath}</span>
                      </div>
                      <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)' }}>
                        <span class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>${formatUnixTs(ch.at)}</span>
                        <button
                          type="button"
                          class="btn-ghost"
                          style=${{ padding: 'var(--sp-0) var(--sp-2)', fontSize: 'var(--fs-11)' }}
                          onClick=${() => handleInspectDiff(ch)}
                        >
                          [⤢] 전체 Diff
                        </button>
                      </div>
                    </div>
                    ${renderDiffLines(patch, 18)}
                  </article>
                `
              })}
        </div>
      `}
    </div>
  `

  return html`
    <div class="ov ov--split" data-testid="infra-repos-tab">
      <header class="ov-head" style=${{ flexShrink: 0 }}>
        <div>
          <span class="ov-eyebrow">6 INFRA · REPOS & 24H CHANGES</span>
          <h1>저장소 관리 · 24시간 Keeper 파일 Diff</h1>
        </div>
      </header>

      ${errorBanner && html`
        <div role="alert" class="ap-error" style=${{ flexShrink: 0 }}>
          ${errorBanner}
        </div>
      `}

      ${!isSingleUser
        ? html`
            <div class="wka-card" data-testid="infra-repos-mode-notice" role="status" style=${{ fontSize: 'var(--fs-13)', color: 'var(--fg-2)' }}>
              저장소 관리 및 24시간 파일 변경 이력(<span class="mono">/api/v1/repositories</span>, <span class="mono">/api/v1/ide/repository-activity</span>)은 single_user 모드 전용입니다.
            </div>
          `
        : html`
            <div style=${{ flex: '1 1 0%', minHeight: 0 }}>
              <${MasterDetail}
                masterLabel="저장소 목록"
                detailLabel="24시간 변경 Diff"
                master=${masterPane}
                detail=${detailPane}
              />
            </div>
          `}
    </div>
  `
}
