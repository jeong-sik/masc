// Repository sidebar — list of repositories with selection and add button.
// Fetches GET /api/v1/repositories and renders a selectable list.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import {
  discoverRepositories,
  fetchRepositoriesList,
  removeRepository,
  requestRepositorySync,
  type RepositoryAdvanceOutcome,
  type Repository,
  type RepoStatus,
} from '../api/repositories'
import { createAsyncResource } from '../lib/async-state'
import { LoadingState, ErrorState } from './common/feedback-state'
import { showToast } from './common/toast'
import { Plus, GitBranch, AlertCircle, PauseCircle, CheckCircle2, HelpCircle, Search } from 'lucide-preact'

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
export const repositorySyncResults = signal<ReadonlyMap<string, RepositoryAdvanceOutcome>>(new Map())

export function repositoryAdvanceSummary(outcome: RepositoryAdvanceOutcome): { message: string; tone: 'success' | 'warning' } {
  switch (outcome.state) {
    case 'advanced': return { message: `${outcome.behind}개 커밋을 작업 트리에 반영했습니다.`, tone: 'success' }
    case 'already_current': return { message: '작업 트리가 이미 최신입니다.', tone: 'success' }
    case 'skipped_dirty': return { message: `원격 갱신 완료. 로컬 변경으로 작업 트리 반영을 건너뛰었습니다. staged ${outcome.staged}, unstaged ${outcome.unstaged}, conflicted ${outcome.conflicted}`, tone: 'warning' }
    case 'skipped_not_on_default_branch': return { message: `원격 갱신 완료. 현재 브랜치 ${outcome.current_branch}를 유지했습니다.`, tone: 'warning' }
    case 'fast_forward_refused': return { message: `원격 갱신 완료. fast-forward 거절 (${outcome.behind}개 커밋): ${outcome.reason}`, tone: 'warning' }
    case 'advance_inspect_failed': return { message: `원격 갱신 완료. 작업 트리 상태 확인 실패: ${outcome.reason}`, tone: 'warning' }
  }
}

// ── API ──────────────────────────────────────────────────

export async function fetchRepositories(): Promise<void> {
  await reposResource.load(async () => {
    return fetchRepositoriesList()
  })
}

export async function syncRepository(id: string): Promise<RepositoryAdvanceOutcome> {
  const nextResults = new Map(repositorySyncResults.value)
  nextResults.delete(id)
  repositorySyncResults.value = nextResults
  try {
    const outcome = await requestRepositorySync(id)
    repositorySyncResults.value = new Map(repositorySyncResults.value).set(id, outcome)
    const summary = repositoryAdvanceSummary(outcome)
    showToast(summary.message, summary.tone)
    return outcome
  } catch (err) {
    const msg = err instanceof Error ? err.message : '동기화 실패'
    showToast(msg, 'error')
    throw err
  }
}

export async function deleteRepository(id: string): Promise<void> {
  try {
    await removeRepository(id)
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

// ── Helpers ──────────────────────────────────────────────

function StatusIcon({ status }: { status: RepoStatus }) {
  switch (status) {
    case 'active':
      return html`<${CheckCircle2} size=${14} class="text-[var(--color-status-ok)]" aria-hidden="true" />`
    case 'paused':
      return html`<${PauseCircle} size=${14} class="text-[var(--color-status-warn)]" aria-hidden="true" />`
    case 'error':
      return html`<${AlertCircle} size=${14} class="text-[var(--color-status-err)]" aria-hidden="true" />`
    case 'unknown':
      // Explicit unknown state surfaces malformed/missing wire data instead
      // of silently coercing it to 'active' (anti-pattern §2 escape).
      return html`<${HelpCircle} size=${14} class="text-[var(--color-fg-muted)]" aria-hidden="true" />`
  }
}

function StatusLabel({ status }: { status: RepoStatus }) {
  switch (status) {
    case 'active':
      return html`<span class="text-xs font-bold text-[var(--color-status-ok)]">활성</span>`
    case 'paused':
      return html`<span class="text-xs font-bold text-[var(--color-status-warn)]">일시정지</span>`
    case 'error':
      return html`<span class="text-xs font-bold text-[var(--color-status-err)]">오류</span>`
    case 'unknown':
      return html`<span class="text-xs font-bold text-[var(--color-fg-secondary)]">알 수 없음</span>`
  }
}

// ── Component ────────────────────────────────────────────

export function RepoSidebar() {
  const state = reposState.value

  if (state.status === 'idle') {
    void fetchRepositories()
  }

  if (state.status === 'loading') {
    return html`
      <div class="v2-workspace-surface flex flex-col h-full">
        <div class="flex items-center justify-between px-3 py-2 border-b border-[var(--color-border-default)]">
          <span class="text-sm font-bold text-[var(--color-fg-secondary)]">저장소</span>
        </div>
        <${LoadingState} class="flex-1">저장소 목록 불러오는 중...<//>
      </div>
    `
  }

  if (state.status === 'error') {
    return html`
      <div class="v2-workspace-surface flex flex-col h-full">
        <div class="flex items-center justify-between px-3 py-2 border-b border-[var(--color-border-default)]">
          <span class="text-sm font-bold text-[var(--color-fg-secondary)]">저장소</span>
          <button
            type="button"
            class="text-xs font-semibold px-2 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-accent-fg)] cursor-pointer transition-colors"
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
    <div class="v2-workspace-surface flex flex-col h-full">
      <div class="flex items-center justify-between px-3 py-2 border-b border-[var(--color-border-default)]">
        <span class="text-sm font-bold text-[var(--color-fg-secondary)]">
          저장소 <span class="text-[var(--color-fg-secondary)] font-normal">(${repos.length})</span>
        </span>
        <div class="flex items-center gap-1">
          <button
            type="button"
            title="base path 아래 git 저장소 스캔"
            aria-label="base path 아래 git 저장소 스캔"
            disabled=${isScanningRepositories.value}
            class="flex items-center gap-1 text-xs font-semibold px-2 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-accent-fg)] disabled:opacity-60 disabled:cursor-not-allowed cursor-pointer transition-colors"
            onClick=${() => { void scanRepositories() }}
          >
            <${Search} size=${12} aria-hidden="true" />
            ${isScanningRepositories.value ? '스캔 중' : '스캔'}
          </button>
          <button
            type="button"
            class="flex items-center gap-1 text-xs font-semibold px-2 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-accent-fg)] cursor-pointer transition-colors"
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
            <div class="px-3 py-6 text-center text-xs text-[var(--color-fg-secondary)]">
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
                class="w-full text-left px-3 py-2 cursor-pointer transition-colors border-l-2 ${isSelected ? 'bg-[var(--color-bg-hover)] border-l-[var(--color-accent-fg)]' : 'border-l-transparent hover:bg-[var(--color-bg-elevated)]'}"
                onClick=${() => { selectRepo(repo.id) }}
                aria-pressed=${isSelected ? 'true' : 'false'}
              >
                <div class="flex items-center gap-2">
                  <${StatusIcon} status=${repo.status} />
                  <span class="text-sm font-semibold ${isSelected ? 'text-[var(--color-fg-primary)]' : 'text-[var(--color-fg-secondary)]'} truncate flex-1">
                    ${repo.name}
                  </span>
                </div>
                <div class="flex items-center gap-2 mt-1 ml-5">
                  <${StatusLabel} status=${repo.status} />
                  <span class="text-xs text-[var(--color-fg-secondary)] flex items-center gap-1">
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
