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
import { createTwoFilesPatch } from 'diff'
import { useEffect, useState } from 'preact/hooks'
import {
  apiGet,
  apiMutate,
  apiRequest,
  resourceCache,
} from '../../core'
import { MasterDetail } from '../../components/primitives'
import { KeeperBadge } from '../../components/keeper-badge'
import {
  extractChangeBeforeAfter,
  extractChangePath,
  formatUnixTs,
  type InfraRepository,
  type RepoActivityChange,
  type RepoActivityData,
  type WorkspaceViewProps,
} from './types'

function normalizeRepoList(raw: unknown): readonly InfraRepository[] {
  let rows: unknown[] = []
  if (Array.isArray(raw)) rows = raw
  else if (raw && typeof raw === 'object') {
    const rec = raw as Record<string, unknown>
    if (Array.isArray(rec.repositories)) rows = rec.repositories
    else if (rec.ok === true && Array.isArray(rec.data)) rows = rec.data
  }
  return rows
    .filter((r): r is Record<string, unknown> => typeof r === 'object' && r !== null)
    .map((r) => ({
      id: typeof r.id === 'string' ? r.id : '',
      name: typeof r.name === 'string' ? r.name : '',
      url: typeof r.url === 'string' ? r.url : '',
      codebase: typeof r.codebase === 'string' ? r.codebase : null,
      local_path: typeof r.local_path === 'string' ? r.local_path : '',
      default_branch: typeof r.default_branch === 'string' ? r.default_branch : 'main',
      status: typeof r.status === 'string' ? r.status : 'unknown',
      auto_sync: r.auto_sync === true,
      sync_interval: typeof r.sync_interval === 'number' ? r.sync_interval : 300,
    }))
    .filter((r) => r.id !== '' && r.name !== '')
}

export function buildUnifiedChangeDiff(change: RepoActivityChange): string {
  const filePath = extractChangePath(change.location)
  const { before, after, unified } = extractChangeBeforeAfter(change.change)
  if (unified) return unified
  return createTwoFilesPatch(`a/${filePath}`, `b/${filePath}`, before, after, 'before', 'after', { context: 3 })
}

function renderDiffLines(patchText: string, maxLines = 40) {
  const allLines = patchText.split('\n')
  const truncated = allLines.length > maxLines
  const lines = truncated ? allLines.slice(0, maxLines) : allLines

  return html`
    <pre
      class="mono"
      style=${{
        margin: 0,
        padding: 'var(--sp-2)',
        background: 'var(--bg-0)',
        border: '1px solid var(--line-1)',
        borderRadius: 'var(--radius-sm)',
        fontSize: 'var(--fs-11)',
        overflowX: 'auto',
        lineHeight: 1.45,
      }}
    >
      ${lines.map((line, i) => {
        const isAdd = line.startsWith('+') && !line.startsWith('+++')
        const isDel = line.startsWith('-') && !line.startsWith('---')
        const isHunk = line.startsWith('@@')
        const style = isAdd
          ? { display: 'block', background: 'var(--ok-soft)', color: 'var(--ok-fg)' }
          : isDel
            ? { display: 'block', background: 'var(--err-soft)', color: 'var(--err-fg)' }
            : isHunk
              ? { display: 'block', color: 'var(--info-fg)' }
              : { display: 'block', color: 'var(--fg-2)' }
        return html`<span key=${i} style=${style}>${line}</span>`
      })}
      ${truncated && html`<span style=${{ display: 'block', color: 'var(--fg-3)', marginTop: '4px' }}>… (${allLines.length - maxLines}줄 생략 · [⤢] 전체 보기 클릭)</span>`}
    </pre>
  `
}

export function ReposTab(props: WorkspaceViewProps) {
  const reposObs = resourceCache.observe<readonly InfraRepository[]>('infra:repositories').value
  const [selectedRepoId, setSelectedRepoId] = useState<string | null>(null)
  const [showAddForm, setShowAddForm] = useState(false)
  const [newName, setNewName] = useState('')
  const [newUrl, setNewUrl] = useState('')
  const [newBranch, setNewBranch] = useState('main')
  const [banner, setBanner] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  const repos = reposObs.kind === 'value' ? reposObs.data : []
  const effectiveRepoId = selectedRepoId && repos.some((r) => r.id === selectedRepoId)
    ? selectedRepoId
    : (repos[0]?.id ?? null)

  const activityKey = effectiveRepoId ? `infra:repo-activity:${effectiveRepoId}` : 'infra:repo-activity:none'
  const activityObs = resourceCache.observe<RepoActivityData>(activityKey).value

  const loadRepos = (reason: 'mount' | 'manual' = 'mount') => {
    void resourceCache.fetch<readonly InfraRepository[]>(
      'infra:repositories',
      async (signal) => {
        const res = await apiGet<unknown>('/api/v1/repositories', { signal })
        return res.ok ? { ok: true, value: normalizeRepoList(res.value) } : res
      },
      { ttlMs: 20_000, topics: ['repositories'], reason },
    )
  }

  const loadActivity = (repoId: string, reason: 'mount' | 'manual' = 'mount') => {
    void resourceCache.fetch<RepoActivityData>(
      `infra:repo-activity:${repoId}`,
      (signal) => apiRequest<RepoActivityData>({
        method: 'GET',
        path: `/api/v1/ide/repository-activity?repo_id=${encodeURIComponent(repoId)}&window_hours=24`,
        envelope: 'ok_data',
        signal,
      }),
      { ttlMs: 20_000, topics: ['repository_activity'], reason },
    )
  }

  useEffect(() => {
    loadRepos('mount')
  }, [])

  useEffect(() => {
    if (effectiveRepoId) {
      loadActivity(effectiveRepoId, 'mount')
    }
  }, [effectiveRepoId])

  const handleAddRepo = async (ev: Event) => {
    ev.preventDefault()
    if (!newName.trim() || !newUrl.trim()) return
    setBusy('add')
    setBanner(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/repositories', {
      name: newName.trim(),
      url: newUrl.trim(),
      default_branch: newBranch.trim() || 'main',
      auto_sync: true,
      sync_interval: 300,
    })
    setBusy(null)
    if (!res.ok) {
      setBanner({ kind: 'err', text: `저장소 등록 실패: ${res.error.message}` })
      return
    }
    setBanner({ kind: 'ok', text: `저장소 '${newName.trim()}' 등록 완료.` })
    setNewName('')
    setNewUrl('')
    setShowAddForm(false)
    loadRepos('manual')
  }

  const handleSyncRepo = async (repoId: string) => {
    setBusy(`sync:${repoId}`)
    setBanner(null)
    const res = await apiMutate<unknown>('POST', `/api/v1/repositories/${encodeURIComponent(repoId)}/sync`, {})
    setBusy(null)
    if (!res.ok) {
      setBanner({ kind: 'err', text: `동기화 실패: ${res.error.message}` })
      return
    }
    setBanner({ kind: 'ok', text: `${repoId} 동기화 완료.` })
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
  const selectedRepo = repos.find((r) => r.id === effectiveRepoId) ?? null

  const masterPane = html`
    <div style=${{ padding: 'var(--sp-3)', display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', minWidth: 0 }}>
      <div class="wka-h">
        <h3>등록된 저장소 (${repos.length})</h3>
        <button type="button" class="btn-primary" onClick=${() => setShowAddForm((v) => !v)}>
          ${showAddForm ? '취소' : '+ 저장소 추가'}
        </button>
      </div>

      ${showAddForm && html`
        <form onSubmit=${handleAddRepo} style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', padding: 'var(--sp-2)', background: 'var(--bg-2)', border: '1px solid var(--line-1)', borderRadius: 'var(--radius-sm)' }}>
          <input
            type="text"
            placeholder="이름 (예: masc)"
            value=${newName}
            onInput=${(e: Event) => setNewName((e.target as HTMLInputElement).value)}
            required
            style=${{ padding: '6px 8px', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
          />
          <input
            type="text"
            placeholder="Git URL 또는 로컬 경로"
            value=${newUrl}
            onInput=${(e: Event) => setNewUrl((e.target as HTMLInputElement).value)}
            required
            style=${{ padding: '6px 8px', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
          />
          <div style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
            <input
              type="text"
              placeholder="기본 브랜치 (main)"
              value=${newBranch}
              onInput=${(e: Event) => setNewBranch((e.target as HTMLInputElement).value)}
              style=${{ flex: 1, minWidth: 0, padding: '6px 8px', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
            />
            <button type="submit" class="btn-primary" disabled=${busy === 'add'}>등록</button>
          </div>
        </form>
      `}

      ${repos.length === 0
        ? html`<div class="dtable-absent">${reposObs.kind === 'loading' ? '저장소 불러오는 중…' : '등록된 저장소가 없습니다.'}</div>`
        : repos.map((repo) => {
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
                  gap: '4px',
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
                  <button
                    type="button"
                    class="btn-ghost"
                    style=${{ padding: '2px 6px', fontSize: 'var(--fs-11)' }}
                    disabled=${busy === `sync:${repo.id}`}
                    onClick=${() => void handleSyncRepo(repo.id)}
                  >
                    동기화
                  </button>
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
        ${selectedRepo && html`
          <button type="button" class="btn-ghost" onClick=${() => loadActivity(selectedRepo.id, 'manual')}>새로고침</button>
        `}
      </div>

      ${!selectedRepo && html`<div class="dtable-absent">왼쪽에서 저장소를 선택하세요.</div>`}

      ${selectedRepo && activityObs.kind === 'loading' && html`<div class="dtable-absent">24시간 파일 변경 이력 불러오는 중…</div>`}

      ${selectedRepo && activityObs.kind === 'failed' && html`
        <div class="ap-error" role="alert">변경 이력 조회 실패: ${activityObs.error.message}</div>
      `}

      ${selectedRepo && activityData && html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', minWidth: 0 }}>
          <div class="mono tnum" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
            변경 ${activityData.changes.length}건 · 미완결 ${activityData.incomplete} · 미귀속 ${activityData.unattributed} (window=${activityData.window_hours}h)
          </div>

          ${activityData.changes.length === 0
            ? html`<div class="dtable-absent">최근 24시간 동안 기록된 Keeper 파일 쓰기가 없습니다.</div>`
            : activityData.changes.slice(0, 40).map((ch, idx) => {
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
                          style=${{ padding: '2px 8px', fontSize: 'var(--fs-11)' }}
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
    <div class="ov" data-testid="infra-repos-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">6 INFRA · REPOS & 24H CHANGES</span>
          <h1>저장소 관리 · 24시간 Keeper 파일 Diff</h1>
        </div>
      </header>

      ${banner && html`
        <div
          role="status"
          class=${banner.kind === 'err' ? 'ap-error' : 'wka-card'}
          style=${banner.kind === 'ok' ? { borderColor: 'var(--ok-border)', background: 'var(--ok-soft)', color: 'var(--ok-fg)' } : undefined}
        >
          ${banner.text}
        </div>
      `}

      <${MasterDetail}
        masterLabel="저장소 목록"
        detailLabel="24시간 변경 Diff"
        master=${masterPane}
        detail=${detailPane}
      />
    </div>
  `
}
