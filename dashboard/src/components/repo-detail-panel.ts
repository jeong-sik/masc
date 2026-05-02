// Repository Detail Panel — shows details of the selected repository.
// Displays info, sync action, delete with confirmation, and branches list.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { get } from '../api/core'
import { createAsyncResource } from '../lib/async-state'
import { LoadingState, ErrorState, EmptyState } from './common/feedback-state'
import { selectedRepoId, syncRepository, deleteRepository, type Repository, type RepoStatus } from './repo-sidebar'
import { requestConfirm } from './common/confirm-dialog'
import { StatusBadge as CommonStatusBadge } from './common/status-badge'
import { Trash2, GitBranch, Clock, Calendar, Folder, Link, Shield, RefreshCw } from 'lucide-preact'

// ── Branch type ──────────────────────────────────────────

export interface BranchInfo {
  name: string
  is_default: boolean
  is_remote: boolean
  last_commit_at: string | null
}

// ── State ────────────────────────────────────────────────

const repoDetailResource = createAsyncResource<Repository>()
const repoDetailState = repoDetailResource.state
const branchesResource = createAsyncResource<BranchInfo[]>()
const branchesState = branchesResource.state
const syncing = signal(false)

// ── API ──────────────────────────────────────────────────

export function normalizeBranch(raw: unknown): BranchInfo | null {
  if (!raw || typeof raw !== 'object') return null
  const b = raw as Record<string, unknown>
  const name = typeof b.name === 'string' ? b.name : ''
  if (!name) return null
  return {
    name,
    is_default: b.is_default === true,
    is_remote: b.is_remote === true,
    last_commit_at: typeof b.last_commit_at === 'string' ? b.last_commit_at : null,
  }
}

export function unwrapRepository(raw: unknown): Record<string, unknown> {
  if (!raw || typeof raw !== 'object') throw new Error('Invalid repository response')
  const record = raw as Record<string, unknown>
  if (record.ok === true && record.data && typeof record.data === 'object') {
    return record.data as Record<string, unknown>
  }
  return record
}

export function branchRows(raw: unknown): unknown[] {
  if (Array.isArray(raw)) return raw
  if (raw && typeof raw === 'object') {
    const record = raw as Record<string, unknown>
    if (Array.isArray(record.branches)) return record.branches
    if (record.ok === true && Array.isArray(record.data)) return record.data
  }
  return []
}

export async function loadRepoDetail(id: string): Promise<void> {
  if (repoDetailState.value.status === 'loading') return
  await repoDetailResource.load(async () => {
    const raw = await get<unknown>(`/api/v1/repositories/${encodeURIComponent(id)}`)
    const r = unwrapRepository(raw)
    return {
      id: typeof r.id === 'string' ? r.id : id,
      name: typeof r.name === 'string' ? r.name : '',
      url: typeof r.url === 'string' ? r.url : '',
      local_path: typeof r.local_path === 'string' ? r.local_path : '',
      default_branch: typeof r.default_branch === 'string' ? r.default_branch : 'main',
      status: normalizeRepoStatus(typeof r.status === 'string' ? r.status : undefined),
      auto_sync: r.auto_sync === true,
      sync_interval: typeof r.sync_interval === 'number' ? r.sync_interval : 300,
      credential_id: typeof r.credential_id === 'string' ? r.credential_id : null,
      created_at: typeof r.created_at === 'string' || typeof r.created_at === 'number' ? r.created_at : null,
      updated_at: typeof r.updated_at === 'string' || typeof r.updated_at === 'number' ? r.updated_at : null,
    } as Repository
  })
}

export async function loadRepoBranches(id: string): Promise<void> {
  await branchesResource.load(async () => {
    const raw = await get<unknown>(`/api/v1/repositories/${encodeURIComponent(id)}/branches`)
    return branchRows(raw).map(normalizeBranch).filter((b): b is BranchInfo => b !== null)
  })
}

export function normalizeRepoStatus(raw: string | undefined): RepoStatus {
  switch (raw?.toLowerCase()) {
    case 'active': return 'active'
    case 'paused': return 'paused'
    case 'cloning': return 'active'
    case 'error': return 'error'
    default: return 'active'
  }
}

export function resetRepoDetail(): void {
  repoDetailResource.reset()
  branchesResource.reset()
  syncing.value = false
}

// ── Helpers ──────────────────────────────────────────────

const REPO_STATUS_LABEL: Record<RepoStatus, string> = {
  active: '활성',
  paused: '일시정지',
  error: '오류',
}

export function formatDate(value: string | number | null): string {
  if (value === null || value === '') return '--'
  try {
    const d = typeof value === 'number' ? new Date(value * 1000) : new Date(value)
    if (Number.isNaN(d.getTime())) return String(value)
    return d.toLocaleString('ko-KR', {
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
    })
  } catch {
    return String(value)
  }
}

function InfoRow({
  icon,
  label,
  value,
}: {
  icon?: unknown
  label: string
  value: string | number | boolean | null
}) {
  const displayValue =
    value === null || value === undefined || value === ''
      ? '--'
      : typeof value === 'boolean'
        ? (value ? 'ON' : 'OFF')
        : String(value)
  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-[var(--r-1)] border border-card-border/50 bg-card/20 backdrop-blur-sm hover:bg-card/40 transition-colors shadow-[var(--shadow-1)] mb-1.5">
      <div class="flex items-center gap-2">
        ${icon ? html`<span class="text-[var(--color-fg-muted)]">${icon}</span>` : null}
        <span class="text-xs font-medium text-text-muted">${label}</span>
      </div>
      <span class="text-xs font-semibold text-text-strong">${displayValue}</span>
    </div>
  `
}

// ── Component ────────────────────────────────────────────

export function RepoDetailPanel() {
  const selectedId = selectedRepoId.value

  if (!selectedId) {
    return html`
      <div class="flex flex-col h-full items-center justify-center">
        <${EmptyState} message="저장소를 선택하면 상세 정보가 표시됩니다." />
      </div>
    `
  }

  const detailState = repoDetailState.value
  const branchState = branchesState.value

  // Load on selection change
  if (detailState.status === 'idle' || (detailState.status === 'loaded' && detailState.data.id !== selectedId)) {
    void loadRepoDetail(selectedId)
    void loadRepoBranches(selectedId)
  }

  if (detailState.status === 'loading') {
    return html`<${LoadingState}>저장소 정보 불러오는 중...<//>`
  }

  if (detailState.status === 'error') {
    return html`
      <div class="space-y-3">
        <${ErrorState} message=${detailState.message} />
        <button
          type="button"
          class="text-2xs px-3 py-1.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] cursor-pointer transition-colors"
          onClick=${() => void loadRepoDetail(selectedId)}
        >
          다시 시도
        </button>
      </div>
    `
  }

  if (detailState.status !== 'loaded') return null

  const repo = detailState.data

  async function handleSync() {
    if (syncing.value) return
    syncing.value = true
    try {
      await syncRepository(repo.id)
      await loadRepoDetail(repo.id)
    } finally {
      syncing.value = false
    }
  }

  async function handleDelete() {
    const confirmed = await requestConfirm({
      title: '저장소 삭제',
      message: `${repo.name} 저장소를 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.`,
      confirmText: '삭제',
      cancelText: '취소',
      tone: 'danger',
    })
    if (!confirmed) return
    try {
      await deleteRepository(repo.id)
    } catch {
      // error already toasted by deleteRepository
    }
  }

  const branches = branchState.status === 'loaded' ? branchState.data : []
  const branchesLoading = branchState.status === 'loading'

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <h2 class="text-lg font-semibold text-[var(--color-fg-secondary)]">${repo.name}</h2>
          <${CommonStatusBadge} status=${repo.status} label=${REPO_STATUS_LABEL[repo.status]} />
        </div>
        <div class="flex items-center gap-2">
          <button
            type="button"
            class="flex items-center gap-1.5 px-3 py-1.5 rounded-[var(--r-1)] text-xs font-semibold cursor-pointer border-none bg-[var(--accent-10)] text-accent-fg hover:bg-[var(--accent-20)] transition-colors disabled:opacity-50"
            onClick=${() => void handleSync()}
            disabled=${syncing.value}
          >
            ${syncing.value
              ? html`<${RefreshCw} size=${13} class="animate-spin" aria-hidden="true" />`
              : html`<${RefreshCw} size=${13} aria-hidden="true" />`}
            ${syncing.value ? '동기화 중...' : '지금 동기화'}
          </button>
          <button
            type="button"
            class="flex items-center gap-1.5 px-3 py-1.5 rounded-[var(--r-1)] text-xs font-semibold cursor-pointer border-none bg-[var(--bad-12)] text-[var(--color-status-err)] hover:bg-[var(--bad-20)] transition-colors"
            onClick=${() => void handleDelete()}
          >
            <${Trash2} size=${13} aria-hidden="true" />
            삭제
          </button>
        </div>
      </div>

      <div class="space-y-1">
        <${InfoRow}
          icon=${html`<${Link} size=${14} />`}
          label="URL"
          value=${repo.url}
        />
        <${InfoRow}
          icon=${html`<${Folder} size=${14} />`}
          label="로컬 경로"
          value=${repo.local_path}
        />
        <${InfoRow}
          icon=${html`<${GitBranch} size=${14} />`}
          label="기본 브랜치"
          value=${repo.default_branch}
        />
        <${InfoRow}
          icon=${html`<${Shield} size=${14} />`}
          label="자동 동기화"
          value=${repo.auto_sync}
        />
        ${repo.auto_sync
          ? html`<${InfoRow} icon=${html`<${Clock} size=${14} />`} label="동기화 간격" value="${repo.sync_interval}s" />`
          : null}
        <${InfoRow}
          icon=${html`<${Calendar} size=${14} />`}
          label="등록일"
          value=${formatDate(repo.created_at)}
        />
        <${InfoRow}
          icon=${html`<${Calendar} size=${14} />`}
          label="수정일"
          value=${formatDate(repo.updated_at)}
        />
      </div>

      <div>
        <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-accent-fg mt-4 mb-3 pb-1.5 border-b border-[var(--accent-20)] flex items-center gap-2">
          <span class="w-1.5 h-1.5 rounded-full bg-[var(--accent-50)] shadow-[0_0_8px_rgb(var(--info-glow)/0.6)]" aria-hidden="true"></span>
          브랜치 목록
        </div>

        ${branchesLoading
          ? html`<${LoadingState} class="py-4">브랜치 목록 불러오는 중...<//>`
          : branchState.status === 'error'
            ? html`<${ErrorState} message=${branchState.message} />`
          : branches.length === 0
            ? html`
              <div class="py-4 text-center text-2xs text-[var(--color-fg-muted)]">
                브랜치 정보가 없습니다.
              </div>
            `
            : html`
              <div class="space-y-1">
                ${branches.map(branch => html`
                  <div
                    key=${branch.name}
                    class="flex items-center justify-between py-2 px-3 rounded-[var(--r-1)] border border-card-border/50 bg-card/20 backdrop-blur-sm"
                  >
                    <div class="flex items-center gap-2">
                      <${GitBranch} size=${12} class="text-[var(--color-fg-muted)]" aria-hidden="true" />
                      <span class="text-xs font-medium text-text-strong">${branch.name}</span>
                      ${branch.is_default
                        ? html`<span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--accent-10)] text-accent-fg border border-[var(--accent-20)]">기본</span>`
                        : null}
                      ${branch.is_remote
                        ? html`<span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] text-text-dim border border-[var(--color-border-default)]">원격</span>`
                        : null}
                    </div>
                    ${branch.last_commit_at
                      ? html`<span class="text-2xs text-[var(--color-fg-muted)]">${formatDate(branch.last_commit_at)}</span>`
                      : null}
                  </div>
                `)}
              </div>
            `
        }
      </div>
    </div>
  `
}
