// Repository sidebar — list of repositories with selection and add button.
// Fetches GET /api/v1/repositories and renders a selectable list.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { authHeaders, post } from '../api/core'
import {
  discoverRepositories,
  fetchRepositoriesList,
  type Repository,
  type RepoStatus,
} from '../api/repositories'
import { createAsyncResource } from '../lib/async-state'
import { LoadingState, ErrorState } from './common/feedback-state'
import { showToast } from './common/toast'
import { Plus, GitBranch, AlertCircle, PauseCircle, CheckCircle2, Search } from 'lucide-preact'

export type { Repository, RepoStatus } from '../api/repositories'
export {
  discoverRepositories,
  normalizeRepoStatus,
  repositoryRows,
  normalizeRepository,
} from '../api/repositories'

// ── State ────────────────────────────────────────────────

const reposResource = createAsyncResource<Repository[]>()
const reposState = reposResource.state
export const selectedRepoId = signal<string | null>(null)
export const showAddRepoDialog = signal(false)
export const isScanningRepositories = signal(false)

// ── API ──────────────────────────────────────────────────

export async function fetchRepositories(): Promise<void> {
  await reposResource.load(async () => {
    return fetchRepositoriesList()
  })
}

export async function syncRepository(id: string): Promise<void> {
  try {
    await post(`/api/v1/repositories/${encodeURIComponent(id)}/sync`, {})
    showToast('동기화 요청 완료', 'success')
  } catch (err) {
    const msg = err instanceof Error ? err.message : '동기화 실패'
    showToast(msg, 'error')
    throw err
  }
}

export async function deleteRepository(id: string): Promise<void> {
  try {
    const res = await fetch(`/api/v1/repositories/${encodeURIComponent(id)}`, {
      method: 'DELETE',
      headers: authHeaders(),
    })
    if (!res.ok) {
      const text = await res.text().catch(() => '삭제 실패')
      throw new Error(text || '삭제 실패')
    }
    showToast('저장소 삭제 완료', 'success')
    await fetchRepositories()
    if (selectedRepoId.value === id) {
      selectedRepoId.value = null
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : '삭제 실패'
    showToast(msg, 'error')
    throw err
  }
}

export async function scanRepositories(): Promise<void> {
  if (isScanningRepositories.value) return
  isScanningRepositories.value = true
  try {
    const registered = await discoverRepositories()
    await fetchRepositories()
    showToast(
      registered.length > 0
        ? `${registered.length}개 저장소 등록 완료`
        : '새 저장소 없음',
      'success',
    )
  } catch (err) {
    const msg = err instanceof Error ? err.message : '저장소 스캔 실패'
    showToast(msg, 'error')
    throw err
  } finally {
    isScanningRepositories.value = false
  }
}

function selectRepo(id: string | null): void {
  selectedRepoId.value = id
}

export function resetRepoSelection(): void {
  selectedRepoId.value = null
  reposResource.reset()
}

// ── Helpers ──────────────────────────────────────────────

function StatusIcon({ status }: { status: RepoStatus }) {
  switch (status) {
    case 'active':
      return html`<${CheckCircle2} size=${14} class="text-[var(--color-status-ok)]" aria-hidden="true" />`
    case 'paused':
      return html`<${PauseCircle} size=${14} class="text-[var(--color-status-warn)]" aria-hidden="true" />`
    case 'error':
      return html`<${AlertCircle} size=${14} class="text-[var(--color-status-err)]" aria-hidden="true" />`
  }
}

function StatusLabel({ status }: { status: RepoStatus }) {
  const label = status === 'active' ? '활성' : status === 'paused' ? '일시정지' : '오류'
  const colorClass =
    status === 'active'
      ? 'text-[var(--color-status-ok)]'
      : status === 'paused'
        ? 'text-[var(--color-status-warn)]'
        : 'text-[var(--color-status-err)]'
  return html`<span class="text-2xs font-medium ${colorClass}">${label}</span>`
}

// ── Component ────────────────────────────────────────────

export function RepoSidebar() {
  const state = reposState.value

  if (state.status === 'idle') {
    void fetchRepositories()
  }

  if (state.status === 'loading') {
    return html`
      <div class="flex flex-col h-full">
        <div class="flex items-center justify-between px-3 py-2 border-b border-[var(--color-border-default)]">
          <span class="text-xs font-semibold text-[var(--color-fg-secondary)]">저장소</span>
        </div>
        <${LoadingState} class="flex-1">저장소 목록 불러오는 중...<//>
      </div>
    `
  }

  if (state.status === 'error') {
    return html`
      <div class="flex flex-col h-full">
        <div class="flex items-center justify-between px-3 py-2 border-b border-[var(--color-border-default)]">
          <span class="text-xs font-semibold text-[var(--color-fg-secondary)]">저장소</span>
          <button
            type="button"
            class="text-2xs px-2 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] cursor-pointer transition-colors"
            onClick=${() => void fetchRepositories()}
          >
            다시 시도
          </button>
        </div>
        <div class="p-3">
          <${ErrorState} message=${state.message} />
        </div>
      </div>
    `
  }

  const repos = state.status === 'loaded' ? state.data : []
  const selected = selectedRepoId.value

  return html`
    <div class="flex flex-col h-full">
      <div class="flex items-center justify-between px-3 py-2 border-b border-[var(--color-border-default)]">
        <span class="text-xs font-semibold text-[var(--color-fg-secondary)]">
          저장소 <span class="text-[var(--color-fg-muted)] font-normal">(${repos.length})</span>
        </span>
        <div class="flex items-center gap-1">
          <button
            type="button"
            title="base path 아래 git 저장소 스캔"
            aria-label="base path 아래 git 저장소 스캔"
            disabled=${isScanningRepositories.value}
            class="flex items-center gap-1 text-2xs px-2 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-accent-fg)] disabled:opacity-60 disabled:cursor-not-allowed cursor-pointer transition-colors"
            onClick=${() => { void scanRepositories() }}
          >
            <${Search} size=${12} aria-hidden="true" />
            ${isScanningRepositories.value ? '스캔 중' : '스캔'}
          </button>
          <button
            type="button"
            class="flex items-center gap-1 text-2xs px-2 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-accent-fg)] cursor-pointer transition-colors"
            onClick=${() => { showAddRepoDialog.value = true }}
          >
            <${Plus} size=${12} aria-hidden="true" />
            추가
          </button>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto py-1">
        ${repos.length === 0
          ? html`
            <div class="px-3 py-6 text-center text-2xs text-[var(--color-fg-muted)]">
              등록된 저장소가 없습니다.
              <div class="mt-1">
                <button
                  type="button"
                  class="text-accent-fg hover:underline cursor-pointer"
                  onClick=${() => { showAddRepoDialog.value = true }}
                >
                  저장소 추가하기
                </button>
              </div>
            </div>
          `
          : repos.map((repo: Repository) => {
            const isSelected = selected === repo.id
            return html`
              <button
                key=${repo.id}
                type="button"
                class="w-full text-left px-3 py-2 cursor-pointer transition-colors border-l-2 ${isSelected ? 'bg-[var(--accent-10)] border-l-accent' : 'border-l-transparent hover:bg-[var(--color-bg-elevated)]'}"
                onClick=${() => { selectRepo(repo.id) }}
                aria-pressed=${isSelected ? 'true' : 'false'}
              >
                <div class="flex items-center gap-2">
                  <${StatusIcon} status=${repo.status} />
                  <span class="text-xs font-medium text-[var(--color-fg-secondary)] truncate flex-1">
                    ${repo.name}
                  </span>
                </div>
                <div class="flex items-center gap-2 mt-1 ml-5">
                  <${StatusLabel} status=${repo.status} />
                  <span class="text-2xs text-[var(--color-fg-muted)] flex items-center gap-1">
                    <${GitBranch} size=${10} aria-hidden="true" />
                    ${repo.default_branch}
                  </span>
                </div>
              </button>
            `
          })}
      </div>
    </div>
  `
}
