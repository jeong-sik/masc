// Credential settings -- page/component for managing credentials.
// Fetches from GET /api/v1/credentials and supports add/delete.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { authHeaders, get, post } from '../api/core'
import { createAsyncResource } from '../lib/async-state'
import { showToast } from './common/toast'
import { ErrorState, LoadingState } from './common/feedback-state'

// ── Types ────────────────────────────────────────────────

export type CredentialType = 'github' | 'gitlab' | 'local'

export interface Credential {
  id: string
  name: string
  type: CredentialType
  username: string
  gh_config_dir?: string | null
  ssh_key_path?: string | null
  gpg_key_id?: string | null
  description?: string
  config?: Record<string, unknown>
  created_at?: string
}

export interface CredentialCreatePayload {
  id: string
  name: string
  type: CredentialType
  username: string
  gh_config_dir?: string | null
  ssh_key_path?: string | null
  gpg_key_id?: string | null
  description?: string
  config?: Record<string, unknown>
}

// ── State ────────────────────────────────────────────────

const credentialsResource = createAsyncResource<Credential[]>()
const credentialsState = credentialsResource.state
const saving = signal(false)
const saveError = signal<string | null>(null)
const showAddForm = signal(false)
const deletingId = signal<string | null>(null)

// Add form draft
const addDraft = signal<CredentialCreatePayload>({
  id: '',
  name: '',
  username: '',
  type: 'github',
  description: '',
})

// ── API ──────────────────────────────────────────────────

async function fetchCredentials(): Promise<Credential[]> {
  const data = await get<unknown>('/api/v1/credentials')
  const rows = Array.isArray(data)
    ? data
    : data && typeof data === 'object' && Array.isArray((data as Record<string, unknown>).credentials)
      ? (data as Record<string, unknown>).credentials as unknown[]
      : []
  if (Array.isArray(rows)) {
    return rows.map((row: unknown): Credential => {
      const r = row as Record<string, unknown>
      const username = String(r.username ?? r.name ?? '')
      return {
        id: String(r.id ?? ''),
        name: String(r.name ?? username ?? r.id ?? ''),
        type: coerceCredentialType(r.type ?? r.cred_type),
        username,
        gh_config_dir: typeof r.gh_config_dir === 'string' ? r.gh_config_dir : null,
        ssh_key_path: typeof r.ssh_key_path === 'string' ? r.ssh_key_path : null,
        gpg_key_id: typeof r.gpg_key_id === 'string' ? r.gpg_key_id : null,
        description: r.description ? String(r.description) : undefined,
        config: isRecord(r.config) ? r.config : undefined,
        created_at: r.created_at ? String(r.created_at) : undefined,
      }
    })
  }
  return []
}

async function createCredential(payload: CredentialCreatePayload): Promise<void> {
  await post('/api/v1/credentials', {
    id: payload.id,
    cred_type: payload.type,
    username: payload.username || payload.name,
    gh_config_dir: payload.gh_config_dir ?? null,
    ssh_key_path: payload.ssh_key_path ?? null,
    gpg_key_id: payload.gpg_key_id ?? null,
  })
}

async function deleteCredential(id: string): Promise<void> {
  const res = await fetch(`/api/v1/credentials/${encodeURIComponent(id)}`, {
    method: 'DELETE',
    headers: authHeaders(),
  })
  if (!res.ok) {
    const text = await res.text().catch(() => '삭제 요청 실패')
    throw new Error(text)
  }
}

// ── Helpers ──────────────────────────────────────────────

export function coerceCredentialType(raw: unknown): CredentialType {
  if (raw === 'gitlab') return 'gitlab'
  if (raw === 'local') return 'local'
  return 'github'
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function credentialTypeLabel(type: CredentialType): string {
  switch (type) {
    case 'github': return 'GitHub'
    case 'gitlab': return 'GitLab'
    case 'local': return 'Local'
  }
}

export function credentialTypeBadgeClass(type: CredentialType): string {
  switch (type) {
    case 'github':
      return 'bg-[var(--accent-10)] text-accent border-accent/20'
    case 'gitlab':
      return 'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]'
    case 'local':
      return 'bg-[var(--white-5)] text-text-dim border-[var(--white-10)]'
  }
}

function resetAddDraft() {
  addDraft.value = { id: '', name: '', username: '', type: 'github', description: '' }
  saveError.value = null
}

// ── Load / Refresh ───────────────────────────────────────

export async function loadCredentials(options?: { force?: boolean }): Promise<void> {
  const force = options?.force === true
  if (!force && credentialsState.value.status === 'loaded') return
  if (force) credentialsResource.reset()
  await credentialsResource.load(() => fetchCredentials())
}

export function resetCredentials(): void {
  credentialsResource.reset()
  showAddForm.value = false
  resetAddDraft()
  saving.value = false
  deletingId.value = null
}

// ── Sub-components ───────────────────────────────────────

function SectionHeader({ title }: { title: string }) {
  return html`
    <div class="text-2xs font-bold uppercase tracking-widest text-accent mt-6 mb-3 pb-1.5 border-b border-accent/20 flex items-center gap-2">
      <span class="w-1.5 h-1.5 rounded-full bg-accent/50 shadow-[0_0_8px_rgba(71,184,255,0.6)]" aria-hidden="true"></span>
      ${title}
    </div>
  `
}

function CredentialTypeBadge({ type }: { type: CredentialType }) {
  return html`
    <span class="text-2xs font-bold px-2 py-0.5 rounded border ${credentialTypeBadgeClass(type)} shadow-sm">
      ${credentialTypeLabel(type)}
    </span>
  `
}

// ── Main component ───────────────────────────────────────

export function CredentialSettings() {
  const state = credentialsState.value

  if (state.status === 'idle') {
    void loadCredentials()
  }

  if (state.status === 'idle' || state.status === 'loading') {
    return html`<${LoadingState}>크리덴셜 목록 불러오는 중...<//>`
  }

  if (state.status === 'error') {
    return html`
      <div class="flex flex-col gap-3">
        <${ErrorState} message=${state.message} />
        <button
          type="button"
          class="py-1.5 px-4 rounded text-xs font-semibold cursor-pointer border-none bg-[var(--white-10)] text-text-body self-start"
          onClick=${() => loadCredentials({ force: true })}
        >
          다시 시도
        </button>
      </div>
    `
  }

  const list = state.data
  const isAdding = showAddForm.value
  const isSaving = saving.value
  const draft = addDraft.value

  async function handleSave() {
    if (!draft.id.trim() || !draft.name.trim() || !draft.username.trim()) {
      saveError.value = 'ID, 이름, 사용자명은 필수입니다.'
      return
    }
    saving.value = true
    saveError.value = null
    try {
      await createCredential({
        id: draft.id.trim(),
        name: draft.name.trim(),
        username: draft.username.trim(),
        type: draft.type,
        description: draft.description?.trim() || undefined,
      })
      showToast('크리덴셜 추가 완료', 'success')
      resetAddDraft()
      showAddForm.value = false
      await loadCredentials({ force: true })
    } catch (err) {
      const msg = err instanceof Error ? err.message : '추가 실패'
      saveError.value = msg
      showToast(msg, 'error')
    } finally {
      saving.value = false
    }
  }

  async function handleDelete(id: string) {
    if (!confirm(`크리덴셜 "${id}"을(를) 삭제하시겠습니까?`)) return
    deletingId.value = id
    try {
      await deleteCredential(id)
      showToast('크리덴셜 삭제 완료', 'success')
      await loadCredentials({ force: true })
    } catch (err) {
      const msg = err instanceof Error ? err.message : '삭제 실패'
      showToast(msg, 'error')
    } finally {
      deletingId.value = null
    }
  }

  const btnBase = 'py-1.5 px-4 rounded text-xs font-semibold cursor-pointer border-none'
  const fieldStyle = 'w-full bg-card/60 backdrop-blur-sm text-text-strong text-sm border border-card-border rounded py-2 px-3 font-sans focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50 transition-all duration-[var(--t-med)] shadow-inner'

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-bold text-text-strong">크리덴셜 관리</h2>
        <button
          type="button"
          class="${btnBase} bg-[var(--purple)] text-[#1e1b4b]"
          onClick=${() => {
            showAddForm.value = !isAdding
            if (!isAdding) resetAddDraft()
          }}
        >
          ${isAdding ? '취소' : '크리덴셜 추가'}
        </button>
      </div>

      ${isAdding ? html`
        <div class="rounded border border-card-border/50 bg-card/20 backdrop-blur-sm p-4 shadow-sm">
          <${SectionHeader} title="새 크리덴셜" />
          <div class="flex flex-col gap-3">
            <div>
              <label class="block text-2xs font-semibold uppercase tracking-wider text-text-muted mb-1.5">ID</label>
              <input
                type="text"
                class="${fieldStyle}"
                placeholder="my-credential"
                value=${draft.id}
                onInput=${(e: Event) => { addDraft.value = { ...draft, id: (e.target as HTMLInputElement).value } }}
              />
            </div>
            <div>
              <label class="block text-2xs font-semibold uppercase tracking-wider text-text-muted mb-1.5">이름</label>
              <input
                type="text"
                class="${fieldStyle}"
                placeholder="표시 이름"
                value=${draft.name}
                onInput=${(e: Event) => { addDraft.value = { ...draft, name: (e.target as HTMLInputElement).value } }}
              />
            </div>
            <div>
              <label class="block text-2xs font-semibold uppercase tracking-wider text-text-muted mb-1.5">사용자명</label>
              <input
                type="text"
                class="${fieldStyle}"
                placeholder="github-user"
                value=${draft.username}
                onInput=${(e: Event) => { addDraft.value = { ...draft, username: (e.target as HTMLInputElement).value } }}
              />
            </div>
            <div>
              <label class="block text-2xs font-semibold uppercase tracking-wider text-text-muted mb-1.5">타입</label>
              <select
                class="${fieldStyle}"
                value=${draft.type}
                onChange=${(e: Event) => { addDraft.value = { ...draft, type: coerceCredentialType((e.target as HTMLSelectElement).value) } }}
              >
                <option value="github">GitHub</option>
                <option value="gitlab">GitLab</option>
                <option value="local">Local</option>
              </select>
            </div>
            <div>
              <label class="block text-2xs font-semibold uppercase tracking-wider text-text-muted mb-1.5">설명</label>
              <input
                type="text"
                class="${fieldStyle}"
                placeholder="선택 사항"
                value=${draft.description ?? ''}
                onInput=${(e: Event) => { addDraft.value = { ...draft, description: (e.target as HTMLInputElement).value } }}
              />
            </div>
            ${saveError.value ? html`<span class="text-xs text-[var(--color-status-err)]" role="alert">${saveError.value}</span>` : null}
            <div class="flex gap-2 mt-1">
              <button
                type="button"
                class="${btnBase} bg-[var(--color-status-ok)] text-[#000]"
                onClick=${handleSave}
                disabled=${isSaving}
              >
                ${isSaving ? '저장 중...' : '저장'}
              </button>
              <button
                type="button"
                class="${btnBase} bg-[var(--white-10)] text-text-body"
                onClick=${() => { showAddForm.value = false; resetAddDraft() }}
              >
                취소
              </button>
            </div>
          </div>
        </div>
      ` : null}

      ${list.length === 0 ? html`
        <div class="py-8 text-center text-2xs text-text-muted rounded border border-card-border/30 bg-card/10">
          등록된 크리덴셜이 없습니다.
        </div>
      ` : html`
        <div class="rounded border border-card-border/50 bg-card/20 backdrop-blur-sm overflow-hidden shadow-sm">
          <table class="w-full text-left">
            <thead>
              <tr class="border-b border-card-border/30 bg-card/40">
                <th class="py-2 px-3 text-2xs font-semibold uppercase tracking-wider text-text-muted">ID</th>
                <th class="py-2 px-3 text-2xs font-semibold uppercase tracking-wider text-text-muted">이름</th>
                <th class="py-2 px-3 text-2xs font-semibold uppercase tracking-wider text-text-muted">타입</th>
                <th class="py-2 px-3 text-2xs font-semibold uppercase tracking-wider text-text-muted">설명</th>
                <th class="py-2 px-3 text-2xs font-semibold uppercase tracking-wider text-text-muted text-right">동작</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-card-border/20">
              ${list.map(cred => html`
                <tr class="hover:bg-card/40 transition-colors">
                  <td class="py-2 px-3 text-xs font-mono text-text-body truncate max-w-[12rem]">${cred.id}</td>
                  <td class="py-2 px-3 text-xs font-medium text-text-strong">${cred.name || cred.username}</td>
                  <td class="py-2 px-3">
                    <${CredentialTypeBadge} type=${cred.type} />
                  </td>
                  <td class="py-2 px-3 text-xs text-text-muted truncate max-w-[16rem]">
                    ${cred.description || '--'}
                  </td>
                  <td class="py-2 px-3 text-right">
                    <button
                      type="button"
                      class="text-2xs font-semibold px-2 py-1 rounded bg-[var(--color-status-err)]/10 text-[var(--color-status-err)] border border-[var(--color-status-err)]/20 hover:bg-[var(--color-status-err)]/20 transition-colors cursor-pointer"
                      onClick=${() => handleDelete(cred.id)}
                      disabled=${deletingId.value === cred.id}
                    >
                      ${deletingId.value === cred.id ? '삭제 중...' : '삭제'}
                    </button>
                  </td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      `}
    </div>
  `
}
