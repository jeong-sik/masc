// Add Repository Dialog — modal for registering a new repository.
// POST /api/v1/repositories on submit.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { get, post } from '../api/core'
import { showToast } from './common/toast'
import { fetchRepositories, showAddRepoDialog } from './repo-sidebar'
import { X } from 'lucide-preact'

// ── Types ────────────────────────────────────────────────

export interface CredentialOption {
  id: string
  name: string
}

// ── Form state ───────────────────────────────────────────

const formName = signal('')
const formUrl = signal('')
const formLocalPath = signal('')
const formDefaultBranch = signal('main')
const formCredentialId = signal('')
const formAutoSync = signal(true)
const formSyncInterval = signal(300)
const formSubmitting = signal(false)
const formError = signal<string | null>(null)
const credentialsResource = signal<CredentialOption[]>([])
const credentialsLoading = signal(false)
const credentialsLoaded = signal(false)

function resetForm(): void {
  formName.value = ''
  formUrl.value = ''
  formLocalPath.value = ''
  formDefaultBranch.value = 'main'
  formCredentialId.value = ''
  formAutoSync.value = true
  formSyncInterval.value = 300
  formError.value = null
}

export function openAddRepoDialog(): void {
  resetForm()
  showAddRepoDialog.value = true
  void loadCredentials()
}

export function closeAddRepoDialog(): void {
  showAddRepoDialog.value = false
  resetForm()
}

// ── API ──────────────────────────────────────────────────

async function loadCredentials(): Promise<void> {
  credentialsLoading.value = true
  try {
    const raw = await get<unknown>('/api/v1/credentials')
    const rows = Array.isArray(raw)
      ? raw
      : raw && typeof raw === 'object' && Array.isArray((raw as Record<string, unknown>).credentials)
        ? (raw as Record<string, unknown>).credentials as unknown[]
        : []
    const options: CredentialOption[] = rows
      .filter((item): item is Record<string, unknown> =>
        item !== null && typeof item === 'object',
      )
      .map(item => ({
        id: typeof item.id === 'string' ? item.id : '',
        name: typeof item.name === 'string'
          ? item.name
          : typeof item.username === 'string'
            ? item.username
            : typeof item.id === 'string'
              ? item.id
              : '',
      }))
      .filter(opt => opt.id && opt.name)
    credentialsResource.value = options
  } catch (err) {
    console.warn('[add-repo-dialog] credentials load failed', err)
    credentialsResource.value = []
  } finally {
    credentialsLoading.value = false
    credentialsLoaded.value = true
  }
}

async function submitAddRepo(): Promise<void> {
  if (formSubmitting.value) return

  const name = formName.value.trim()
  const url = formUrl.value.trim()
  const localPath = formLocalPath.value.trim()
  const defaultBranch = formDefaultBranch.value.trim() || 'main'

  if (!name) {
    formError.value = '저장소 이름을 입력하세요.'
    return
  }
  if (!url) {
    formError.value = '저장소 URL을 입력하세요.'
    return
  }
  formSubmitting.value = true
  formError.value = null

  try {
    const payload: Record<string, unknown> = {
      name,
      url,
      default_branch: defaultBranch,
      credential_id: formCredentialId.value || 'default',
      auto_sync: formAutoSync.value,
      sync_interval: Math.max(60, formSyncInterval.value),
    }
    if (localPath) payload.local_path = localPath
    await post('/api/v1/repositories', payload)
    showToast('저장소 등록 완료', 'success')
    closeAddRepoDialog()
    await fetchRepositories()
  } catch (err) {
    const msg = err instanceof Error ? err.message : '저장소 등록 실패'
    formError.value = msg
    showToast(msg, 'error')
  } finally {
    formSubmitting.value = false
  }
}

// ── Styles ───────────────────────────────────────────────

const inputBase =
  'w-full bg-card/60 backdrop-blur-sm text-text-strong text-sm border border-card-border rounded-[var(--r-1)] py-2 px-3 font-sans focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50 transition-all shadow-inner'

const labelBase = 'block text-2xs font-semibold uppercase tracking-wider text-text-muted mb-1.5'

// ── Component ────────────────────────────────────────────

export function AddRepoDialog() {
  const open = showAddRepoDialog.value
  if (!open) return null
  if (!credentialsLoaded.value && !credentialsLoading.value) {
    void loadCredentials()
  }

  const credentials = credentialsResource.value
  const hasCredentials = credentials.length > 0

  return html`
    <div
      class="fixed inset-0 z-[var(--z-overlay-modal,3060)] flex items-center justify-center bg-black/50 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
      aria-labelledby="add-repo-title"
      onClick=${(e: Event) => {
        if (e.target === e.currentTarget) closeAddRepoDialog()
      }}
    >
      <div class="w-full max-w-lg rounded-xl border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] shadow-[var(--shadow-raised)] mx-4">
        <div class="flex items-center justify-between px-4 py-3 border-b border-[var(--color-border-default)]">
          <h2 id="add-repo-title" class="text-sm font-semibold text-[var(--color-fg-secondary)]">
            저장소 추가
          </h2>
          <button
            type="button"
            class="p-1 rounded-[var(--r-1)] text-[var(--color-fg-muted)] hover:text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] cursor-pointer transition-colors"
            aria-label="닫기"
            onClick=${closeAddRepoDialog}
          >
            <${X} size=${16} />
          </button>
        </div>

        <div class="px-4 py-4 space-y-4 max-h-[70vh] overflow-y-auto">
          ${formError.value
            ? html`
              <div class="rounded-[var(--r-1)] border border-[var(--bad-30)] bg-[var(--bad-12)] px-3 py-2 text-xs text-[var(--bad-light)]" role="alert">
                ${formError.value}
              </div>
            `
            : null}

          <div>
            <label class="${labelBase}">이름 <span class="text-[var(--color-status-err)]">*</span></label>
            <input
              type="text"
              class="${inputBase}"
              placeholder="my-project"
              value=${formName.value}
              onInput=${(e: Event) => { formName.value = (e.target as HTMLInputElement).value }}
              disabled=${formSubmitting.value}
            />
          </div>

          <div>
            <label class="${labelBase}">URL <span class="text-[var(--color-status-err)]">*</span></label>
            <input
              type="text"
              class="${inputBase}"
              placeholder="https://github.com/owner/repo.git"
              value=${formUrl.value}
              onInput=${(e: Event) => { formUrl.value = (e.target as HTMLInputElement).value }}
              disabled=${formSubmitting.value}
            />
          </div>

          <div>
            <label class="${labelBase}">로컬 경로</label>
            <input
              type="text"
              class="${inputBase}"
              placeholder=".masc/repos/<저장소-id>"
              value=${formLocalPath.value}
              onInput=${(e: Event) => { formLocalPath.value = (e.target as HTMLInputElement).value }}
              disabled=${formSubmitting.value}
            />
          </div>

          <div>
            <label class="${labelBase}">기본 브랜치</label>
            <input
              type="text"
              class="${inputBase}"
              placeholder="main"
              value=${formDefaultBranch.value}
              onInput=${(e: Event) => { formDefaultBranch.value = (e.target as HTMLInputElement).value }}
              disabled=${formSubmitting.value}
            />
          </div>

          <div>
            <label class="${labelBase}">인증 정보</label>
            <select
              class="${inputBase}"
              value=${formCredentialId.value}
              onChange=${(e: Event) => { formCredentialId.value = (e.target as HTMLSelectElement).value }}
              disabled=${formSubmitting.value || credentialsLoading.value}
            >
              <option value="">선택 안 함</option>
              ${hasCredentials
                ? credentials.map(c => html`<option value=${c.id}>${c.name}</option>`)
                : null}
            </select>
            ${credentialsLoading.value
              ? html`<span class="text-2xs text-[var(--color-fg-muted)] mt-1 block">인증 정보 로딩 중...</span>`
              : !hasCredentials
                ? html`<span class="text-2xs text-[var(--color-fg-muted)] mt-1 block">등록된 인증 정보가 없습니다.</span>`
                : null}
          </div>

          <div class="flex items-center gap-3">
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked=${formAutoSync.value}
                onChange=${(e: Event) => { formAutoSync.value = (e.target as HTMLInputElement).checked }}
                disabled=${formSubmitting.value}
              />
              <span class="text-xs text-[var(--color-fg-secondary)]">자동 동기화</span>
            </label>
          </div>

          ${formAutoSync.value
            ? html`
              <div>
                <label class="${labelBase}">동기화 간격 (초)</label>
                <input
                  type="number"
                  class="${inputBase}"
                  min=${60}
                  step=${60}
                  value=${formSyncInterval.value}
                  onInput=${(e: Event) => {
                    const v = parseInt((e.target as HTMLInputElement).value, 10)
                    formSyncInterval.value = isNaN(v) ? 300 : v
                  }}
                  disabled=${formSubmitting.value}
                />
              </div>
            `
            : null}
        </div>

        <div class="flex items-center justify-end gap-2 px-4 py-3 border-t border-[var(--color-border-default)]">
          <button
            type="button"
            class="px-4 py-1.5 rounded-[var(--r-1)] text-xs font-semibold cursor-pointer border-none bg-[var(--color-bg-hover)] text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] transition-colors"
            onClick=${closeAddRepoDialog}
            disabled=${formSubmitting.value}
          >
            취소
          </button>
          <button
            type="button"
            class="px-4 py-1.5 rounded-[var(--r-1)] text-xs font-semibold cursor-pointer border-none bg-[var(--color-status-ok)] text-[var(--color-fg-on-ok)] hover:opacity-90 transition-opacity disabled:opacity-50"
            onClick=${() => void submitAddRepo()}
            disabled=${formSubmitting.value}
          >
            ${formSubmitting.value ? '등록 중...' : '저장소 등록'}
          </button>
        </div>
      </div>
    </div>
  `
}
