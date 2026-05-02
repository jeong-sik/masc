// Credential settings -- page/component for managing credentials.
// Fetches from GET /api/v1/credentials and supports add/delete.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { authHeaders, get, post } from '../api/core'
import {
  coerceCredentialType,
  normalizeCredentialsResponse,
  type Credential,
  type CredentialCreatePayload,
  type CredentialState,
  type CredentialType,
} from '../api/credentials'
import { createAsyncResource } from '../lib/async-state'
import { showToast } from './common/toast'
import { ErrorState, LoadingState } from './common/feedback-state'

export {
  coerceCredentialType,
  isRecord,
  normalizeCredentialsResponse,
  parseCredentialState,
} from '../api/credentials'
export type {
  Credential,
  CredentialCreatePayload,
  CredentialOauthMethod,
  CredentialState,
  CredentialType,
} from '../api/credentials'

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
  oauth_method: 'web',
  description: '',
})

// ── API ──────────────────────────────────────────────────

async function fetchCredentials(): Promise<Credential[]> {
  const data = await get<unknown>('/api/v1/credentials')
  return normalizeCredentialsResponse(data)
}

async function createCredential(payload: CredentialCreatePayload): Promise<void> {
  await post('/api/v1/credentials', buildCredentialCreateRequest(payload))
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
      return 'bg-[var(--accent-10)] text-accent-fg border-[var(--accent-20)]'
    case 'gitlab':
      return 'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]'
    case 'local':
      return 'bg-[var(--color-bg-elevated)] text-text-dim border-[var(--color-border-default)]'
  }
}

export function credentialStateLabel(state: CredentialState | null | undefined): string {
  switch (state?.kind) {
    case 'Materialized':
      return 'Materialized'
    case 'Stale':
      return 'Stale'
    case 'Unmaterialized':
      return 'Unmaterialized'
    default:
      return 'Unknown'
  }
}

export function credentialStateBadgeClass(state: CredentialState | null | undefined): string {
  switch (state?.kind) {
    case 'Materialized':
      return 'bg-[var(--ok-10)] text-[var(--color-status-ok)] border-[var(--ok-20)]'
    case 'Stale':
      return 'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]'
    case 'Unmaterialized':
      return 'bg-[var(--color-bg-elevated)] text-text-dim border-[var(--color-border-default)]'
    default:
      return 'bg-[var(--color-bg-elevated)] text-text-muted border-[var(--color-border-default)]'
  }
}

export function sanitizeOptionalString(value: string | null | undefined): string | null {
  const trimmed = value?.trim() ?? ''
  return trimmed === '' ? null : trimmed
}

export function shellQuote(value: string): string {
  return `'${value.split("'").join("'\\''")}'`
}

export function githubLoginCommand(ghConfigDir: string | null | undefined): string | null {
  const dir = sanitizeOptionalString(ghConfigDir)
  if (!dir) return null
  return `GH_CONFIG_DIR=${shellQuote(dir)} gh auth login --hostname github.com --git-protocol https --web --clipboard`
}

export function buildCredentialCreateRequest(payload: CredentialCreatePayload): Record<string, unknown> {
  const ghConfigDir = sanitizeOptionalString(payload.gh_config_dir)
  const sshKeyPath = sanitizeOptionalString(payload.ssh_key_path)
  const gpgKeyId = sanitizeOptionalString(payload.gpg_key_id)
  const oauthMethod =
    payload.type === 'github'
      ? payload.oauth_method === 'with_token' ? 'with_token' : 'web'
      : 'web'
  return {
    id: payload.id.trim(),
    cred_type: payload.type,
    username: (payload.username || payload.name).trim(),
    gh_config_dir: ghConfigDir,
    ssh_key_path: sshKeyPath,
    gpg_key_id: gpgKeyId,
    oauth_method: oauthMethod,
    token: oauthMethod === 'with_token' ? sanitizeOptionalString(payload.token) : null,
  }
}

function resetAddDraft() {
  addDraft.value = { id: '', name: '', username: '', type: 'github', oauth_method: 'web', description: '' }
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
    <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-accent-fg mt-6 mb-3 pb-1.5 border-b border-[var(--accent-20)] flex items-center gap-2">
      <span class="w-1.5 h-1.5 rounded-full bg-[var(--accent-50)] shadow-[0_0_8px_rgb(var(--info-glow)/0.6)]" aria-hidden="true"></span>
      ${title}
    </div>
  `
}

function CredentialTypeBadge({ type }: { type: CredentialType }) {
  return html`
    <span class="text-2xs font-bold px-2 py-0.5 rounded-[var(--r-1)] border ${credentialTypeBadgeClass(type)} shadow-1">
      ${credentialTypeLabel(type)}
    </span>
  `
}

function CredentialStateBadge({ state }: { state?: CredentialState | null }) {
  return html`
    <span class="text-2xs font-bold px-2 py-0.5 rounded-[var(--r-1)] border ${credentialStateBadgeClass(state)} shadow-1">
      ${credentialStateLabel(state)}
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
          class="py-1.5 px-4 rounded-[var(--r-1)] text-xs font-semibold cursor-pointer border-none bg-[var(--color-bg-hover)] text-text-body self-start"
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
    if (!draft.id.trim() || !draft.username.trim()) {
      saveError.value = 'ID와 사용자명은 필수입니다.'
      return
    }
    if (draft.type === 'github' && draft.oauth_method === 'with_token' && !sanitizeOptionalString(draft.token)) {
      saveError.value = 'with-token 방식은 token 값이 필요합니다.'
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
        gh_config_dir: sanitizeOptionalString(draft.gh_config_dir),
        ssh_key_path: sanitizeOptionalString(draft.ssh_key_path),
        gpg_key_id: sanitizeOptionalString(draft.gpg_key_id),
        oauth_method: draft.oauth_method ?? 'web',
        token: sanitizeOptionalString(draft.token),
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

  const btnBase = 'py-1.5 px-4 rounded-[var(--r-1)] text-xs font-semibold cursor-pointer border-none'
  const fieldStyle = 'w-full bg-card/60 backdrop-blur-sm text-text-strong text-sm border border-card-border rounded-[var(--r-1)] py-2 px-3 font-sans focus:outline-none focus:border-accent-fg/50 focus:ring-1 focus:ring-accent-fg/50 transition-[border-color,box-shadow] duration-[var(--t-med)] shadow-inset'
  const helperStyle = 'mt-1 text-3xs leading-relaxed text-text-dim'

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-bold text-text-strong">크리덴셜 관리</h2>
        <button
          type="button"
          class="${btnBase} bg-[var(--purple)] text-[var(--color-bg-0)]"
          onClick=${() => {
            showAddForm.value = !isAdding
            if (!isAdding) resetAddDraft()
          }}
        >
          ${isAdding ? '취소' : '크리덴셜 추가'}
        </button>
      </div>

      ${isAdding ? html`
        <div class="rounded-[var(--r-1)] border border-card-border/50 bg-card/20 backdrop-blur-sm p-4 shadow-[var(--shadow-1)]">
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
                placeholder="선택 사항"
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
                onChange=${(e: Event) => {
                  const nextType = coerceCredentialType((e.target as HTMLSelectElement).value)
                  addDraft.value = {
                    ...draft,
                    type: nextType,
                    oauth_method: nextType === 'github' ? draft.oauth_method ?? 'web' : 'web',
                    token: nextType === 'github' ? draft.token ?? '' : '',
                  }
                }}
              >
                <option value="github">GitHub</option>
                <option value="gitlab">GitLab</option>
                <option value="local">Local</option>
              </select>
            </div>
            ${draft.type === 'github' ? html`
              <div>
                <label class="block text-2xs font-semibold uppercase tracking-wider text-text-muted mb-1.5">gh login</label>
                <select
                  class="${fieldStyle}"
                  value=${draft.oauth_method ?? 'web'}
                  onChange=${(e: Event) => {
                    addDraft.value = {
                      ...draft,
                      oauth_method: (e.target as HTMLSelectElement).value === 'with_token' ? 'with_token' : 'web',
                    }
                  }}
                >
                  <option value="web">gh auth login --web</option>
                  <option value="with_token">gh auth login --with-token</option>
                </select>
              </div>
              <div>
                <label class="block text-2xs font-semibold uppercase tracking-wider text-text-muted mb-1.5">GH_CONFIG_DIR</label>
                <input
                  type="text"
                  class="${fieldStyle}"
                  placeholder="base_path/.masc/github-identities/<credential-id>/gh"
                  value=${draft.gh_config_dir ?? ''}
                  onInput=${(e: Event) => { addDraft.value = { ...draft, gh_config_dir: (e.target as HTMLInputElement).value } }}
                />
                <div class="${helperStyle}">비우면 서버 base_path 아래 identity bundle을 사용합니다.</div>
              </div>
              ${draft.oauth_method === 'with_token' ? html`
                <div>
                  <label class="block text-2xs font-semibold uppercase tracking-wider text-text-muted mb-1.5">Token</label>
                  <textarea
                    class="${fieldStyle} min-h-20 resize-y"
                    placeholder="gh auth login --with-token 입력값"
                    value=${draft.token ?? ''}
                    onInput=${(e: Event) => { addDraft.value = { ...draft, token: (e.target as HTMLTextAreaElement).value } }}
                  />
                </div>
              ` : null}
            ` : null}
            ${(draft.type === 'github' || draft.type === 'local') ? html`
              <div>
                <label class="block text-2xs font-semibold uppercase tracking-wider text-text-muted mb-1.5">SSH key path</label>
                <input
                  type="text"
                  class="${fieldStyle}"
                  placeholder="base_path/.masc/github-identities/<credential-id>/ssh/id_ed25519"
                  value=${draft.ssh_key_path ?? ''}
                  onInput=${(e: Event) => { addDraft.value = { ...draft, ssh_key_path: (e.target as HTMLInputElement).value } }}
                />
              </div>
            ` : null}
            <div>
              <label class="block text-2xs font-semibold uppercase tracking-wider text-text-muted mb-1.5">GPG key id</label>
              <input
                type="text"
                class="${fieldStyle}"
                placeholder="선택 사항"
                value=${draft.gpg_key_id ?? ''}
                onInput=${(e: Event) => { addDraft.value = { ...draft, gpg_key_id: (e.target as HTMLInputElement).value } }}
              />
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
                class="${btnBase} bg-[var(--color-status-ok)] text-[var(--color-fg-on-ok)]"
                onClick=${handleSave}
                disabled=${isSaving}
              >
                ${isSaving ? '저장 중...' : '저장'}
              </button>
              <button
                type="button"
                class="${btnBase} bg-[var(--color-bg-hover)] text-text-body"
                onClick=${() => { showAddForm.value = false; resetAddDraft() }}
              >
                취소
              </button>
            </div>
          </div>
        </div>
      ` : null}

      ${list.length === 0 ? html`
        <div class="py-8 text-center text-2xs text-text-muted rounded-[var(--r-1)] border border-card-border/30 bg-card/10">
          등록된 크리덴셜이 없습니다.
        </div>
      ` : html`
        <div class="rounded-[var(--r-1)] border border-card-border/50 bg-card/20 backdrop-blur-sm overflow-hidden shadow-[var(--shadow-1)]">
          <table class="w-full text-left">
            <thead>
              <tr class="border-b border-card-border/30 bg-card/40">
                <th class="py-2 px-3 text-2xs font-semibold uppercase tracking-wider text-text-muted">ID</th>
                <th class="py-2 px-3 text-2xs font-semibold uppercase tracking-wider text-text-muted">계정</th>
                <th class="py-2 px-3 text-2xs font-semibold uppercase tracking-wider text-text-muted">타입</th>
                <th class="py-2 px-3 text-2xs font-semibold uppercase tracking-wider text-text-muted">상태</th>
                <th class="py-2 px-3 text-2xs font-semibold uppercase tracking-wider text-text-muted">경로</th>
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
                  <td class="py-2 px-3">
                    <div class="flex flex-col gap-1">
                      <${CredentialStateBadge} state=${cred.state} />
                      ${cred.token_sha256_prefix ? html`
                        <span class="text-3xs font-mono text-text-dim">token ${cred.token_sha256_prefix}</span>
                      ` : null}
                      ${cred.state?.kind === 'Stale' && cred.state.reason ? html`
                        <span class="text-3xs text-[var(--color-status-warn)] max-w-[12rem] break-words">${cred.state.reason}</span>
                      ` : null}
                    </div>
                  </td>
                  <td class="py-2 px-3 text-xs text-text-muted max-w-[28rem]">
                    <div class="flex flex-col gap-1">
                      ${cred.gh_config_dir ? html`
                        <code class="font-mono text-3xs text-text-body break-all">${cred.gh_config_dir}</code>
                      ` : html`<span class="text-3xs text-text-dim">GH_CONFIG_DIR --</span>`}
                      ${githubLoginCommand(cred.gh_config_dir) && cred.state?.kind !== 'Materialized' ? html`
                        <code class="font-mono text-3xs text-accent-fg break-all">${githubLoginCommand(cred.gh_config_dir)}</code>
                      ` : null}
                      ${cred.ssh_key_path ? html`
                        <code class="font-mono text-3xs text-text-dim break-all">ssh ${cred.ssh_key_path}</code>
                      ` : null}
                    </div>
                  </td>
                  <td class="py-2 px-3 text-right">
                    <button
                      type="button"
                      class="text-2xs font-semibold px-2 py-1 rounded-[var(--r-1)] bg-[var(--color-status-err)]/10 text-[var(--color-status-err)] border border-[var(--color-status-err)]/20 hover:bg-[var(--color-status-err)]/20 transition-colors cursor-pointer"
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
