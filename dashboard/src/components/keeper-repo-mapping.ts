// Keeper-repo mapping -- page/component for mapping keepers to repositories.
// Fetches keepers list and allows multi-select assignment per keeper.
// Save sends POST /api/v1/keeper-repos/:id

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { get, post } from '../api/core'
import {
  normalizeCredentialsResponse,
  type CredentialState,
  type CredentialType,
} from '../api/credentials'
import { createAsyncResource } from '../lib/async-state'
import { showToast } from './common/toast'
import { ErrorState, LoadingState } from './common/feedback-state'
import {
  credentialStateBadgeClass,
  credentialStateLabel,
  githubLoginCommand,
} from './credential-settings'
import type { Keeper } from '../types'

// ── Types ────────────────────────────────────────────────

export interface RepositoryOption {
  id: string
  name: string
  url?: string
}

export interface KeeperRepoMapping {
  keeper_id: string
  keeper_name: string
  allowed_repos: string[]
  allow_all: boolean
  credential_id?: string | null
}

export interface KeeperCredentialOption {
  id: string
  name: string
  type: CredentialType
  username: string
  gh_config_dir?: string | null
  state?: CredentialState | null
}

// ── State ────────────────────────────────────────────────

const keepersResource = createAsyncResource<Keeper[]>()
const keepersState = keepersResource.state

const reposResource = createAsyncResource<RepositoryOption[]>()
const reposState = reposResource.state

const credentialsResource = createAsyncResource<KeeperCredentialOption[]>()
const credentialsState = credentialsResource.state

const mappingsResource = createAsyncResource<KeeperRepoMapping[]>()
const mappingsState = mappingsResource.state

const savingKeeperId = signal<string | null>(null)
const saveError = signal<string | null>(null)

// Local draft: keeper_id -> Set of repo ids or '*' for all
const draftMappings = signal<Map<string, Set<string> | '*'>>(new Map())
const draftCredentials = signal<Map<string, string | null>>(new Map())

// ── API ──────────────────────────────────────────────────

async function fetchKeepers(): Promise<Keeper[]> {
  const { fetchDashboardExecution } = await import('../api/dashboard')
  const data = await fetchDashboardExecution()
  const raw = Array.isArray(data.keepers) ? data.keepers : []
  return raw.filter((k): k is Keeper =>
    k !== null && typeof k === 'object' &&
    (typeof (k as Keeper).keeper_id === 'string' || typeof (k as Keeper).name === 'string')
  )
}

async function fetchRepositories(): Promise<RepositoryOption[]> {
  const data = await get<unknown>('/api/v1/repositories')
  const rows = Array.isArray(data)
    ? data
    : data && typeof data === 'object' && Array.isArray((data as Record<string, unknown>).repositories)
      ? (data as Record<string, unknown>).repositories as unknown[]
      : []
  if (Array.isArray(rows)) {
    return rows.map((row: unknown): RepositoryOption => {
      const r = row as Record<string, unknown>
      return {
        id: String(r.id ?? ''),
        name: String(r.name ?? r.id ?? ''),
        url: r.url ? String(r.url) : undefined,
      }
    })
  }
  return []
}

async function fetchCredentials(): Promise<KeeperCredentialOption[]> {
  const data = await get<unknown>('/api/v1/credentials')
  return normalizeCredentialsResponse(data).filter(cred => cred.id !== '')
}

async function fetchKeeperRepoMappings(): Promise<KeeperRepoMapping[]> {
  const data = await get<unknown>('/api/v1/keeper-repos')
  const rows = Array.isArray(data)
    ? data
    : data && typeof data === 'object' && Array.isArray((data as Record<string, unknown>).mappings)
      ? (data as Record<string, unknown>).mappings as unknown[]
      : []
  if (Array.isArray(rows)) {
    return rows.map((row: unknown): KeeperRepoMapping => {
      const r = row as Record<string, unknown>
      return {
        keeper_id: String(r.keeper_id ?? ''),
        keeper_name: String(r.keeper_name ?? ''),
        allowed_repos: Array.isArray(r.allowed_repos)
          ? r.allowed_repos.filter((v): v is string => typeof v === 'string')
          : Array.isArray(r.repositories)
            ? r.repositories.filter((v): v is string => typeof v === 'string')
          : [],
        allow_all: r.allow_all === true,
        credential_id: normalizeCredentialId(typeof r.credential_id === 'string' ? r.credential_id : null),
      }
    })
  }
  return []
}

async function saveKeeperRepos(
  keeperId: string,
  repos: string[],
  credentialId: string | null,
): Promise<void> {
  await post(`/api/v1/keeper-repos/${encodeURIComponent(keeperId)}`, {
    repositories: repos,
    credential_id: normalizeCredentialId(credentialId),
  })
}

// ── Helpers ──────────────────────────────────────────────

function getDraftForKeeper(keeperId: string, fallback: Set<string> | '*'): Set<string> | '*' {
  const draft = draftMappings.value.get(keeperId)
  return draft !== undefined ? draft : fallback
}

function getDraftCredentialForKeeper(keeperId: string, fallback: string | null): string | null {
  const draft = draftCredentials.value.get(keeperId)
  return draft !== undefined ? draft : fallback
}

export function normalizeCredentialId(value: string | null | undefined): string | null {
  const trimmed = value?.trim() ?? ''
  return trimmed === '' ? null : trimmed
}

export function isRepoSelected(_keeperId: string, repoId: string, current: Set<string> | '*'): boolean {
  if (current === '*') return true
  return current.has(repoId)
}

export function isAllowAll(_keeperId: string, current: Set<string> | '*'): boolean {
  return current === '*'
}

function toggleRepo(_keeperId: string, repoId: string, current: Set<string> | '*'): Set<string> | '*' {
  if (current === '*') {
    // Switch from '*' to explicit set with this repo removed
    const next = new Set<string>()
    const repos = reposState.value.status === 'loaded' ? reposState.value.data : []
    for (const r of repos) {
      if (r.id !== repoId) next.add(r.id)
    }
    return next
  }
  const next = new Set(current)
  if (next.has(repoId)) {
    next.delete(repoId)
  } else {
    next.add(repoId)
  }
  return next
}

export function toggleAllowAll(_keeperId: string, current: Set<string> | '*'): Set<string> | '*' {
  return current === '*' ? new Set<string>() : '*'
}

export function hasChanges(_keeperId: string, original: Set<string> | '*', draft: Set<string> | '*'): boolean {
  if (original === '*' && draft === '*') return false
  if (original === '*' || draft === '*') return true
  if (original.size !== draft.size) return true
  for (const id of original) {
    if (!draft.has(id)) return true
  }
  return false
}

export function hasCredentialChange(
  _keeperId: string,
  original: string | null | undefined,
  draft: string | null | undefined,
): boolean {
  return normalizeCredentialId(original) !== normalizeCredentialId(draft)
}

export function buildRepoSetFromMapping(mapping: KeeperRepoMapping): Set<string> | '*' {
  if (mapping.allow_all) return '*'
  return new Set(mapping.allowed_repos)
}

export function buildCredentialIdFromMapping(mapping: KeeperRepoMapping): string | null {
  return normalizeCredentialId(mapping.credential_id)
}

// ── Load / Refresh ───────────────────────────────────────

export async function loadKeeperRepoMappings(options?: { force?: boolean }): Promise<void> {
  const force = options?.force === true

  const loadKeepers = async () => {
    if (!force && keepersState.value.status === 'loaded') return
    if (force) keepersResource.reset()
    await keepersResource.load(() => fetchKeepers())
  }

  const loadRepos = async () => {
    if (!force && reposState.value.status === 'loaded') return
    if (force) reposResource.reset()
    await reposResource.load(() => fetchRepositories())
  }

  const loadCredentials = async () => {
    if (!force && credentialsState.value.status === 'loaded') return
    if (force) credentialsResource.reset()
    await credentialsResource.load(() => fetchCredentials())
  }

  const loadMappings = async () => {
    if (!force && mappingsState.value.status === 'loaded') return
    if (force) mappingsResource.reset()
    await mappingsResource.load(() => fetchKeeperRepoMappings())
  }

  await Promise.all([loadKeepers(), loadRepos(), loadCredentials(), loadMappings()])

  // Initialize drafts from loaded mappings
  if (mappingsState.value.status === 'loaded' && (force || draftMappings.value.size === 0)) {
    const nextMappings = new Map<string, Set<string> | '*'>()
    const nextCredentials = new Map<string, string | null>()
    for (const m of mappingsState.value.data) {
      nextMappings.set(m.keeper_id, buildRepoSetFromMapping(m))
      nextCredentials.set(m.keeper_id, buildCredentialIdFromMapping(m))
    }
    // Also initialize empty drafts for keepers without mappings
    if (keepersState.value.status === 'loaded') {
      for (const k of keepersState.value.data) {
        const id = k.keeper_id ?? k.name
        if (!nextMappings.has(id)) {
          nextMappings.set(id, '*')
          nextCredentials.set(id, null)
        }
      }
    }
    draftMappings.value = nextMappings
    draftCredentials.value = nextCredentials
  }
}

export function resetKeeperRepoMappings(): void {
  keepersResource.reset()
  reposResource.reset()
  credentialsResource.reset()
  mappingsResource.reset()
  draftMappings.value = new Map()
  draftCredentials.value = new Map()
  savingKeeperId.value = null
  saveError.value = null
}

// ── Sub-components ───────────────────────────────────────

function RepoBadge({ name }: { name: string }) {
  return html`
    <span class="inline-flex items-center py-1 px-2.5 rounded-[var(--r-1)] text-2xs font-semibold bg-[var(--accent-10)] text-accent border border-accent/20 shadow-sm">
      ${name}
    </span>
  `
}

// ── Main component ───────────────────────────────────────

export function KeeperRepoMapping() {
  const kState = keepersState.value
  const rState = reposState.value
  const cState = credentialsState.value
  const mState = mappingsState.value

  // Trigger load on first render
  if (kState.status === 'idle') {
    void loadKeeperRepoMappings()
  }

  if (kState.status === 'loading' || rState.status === 'loading' || cState.status === 'loading' || mState.status === 'loading') {
    return html`<${LoadingState}>키퍼와 저장소 정보 불러오는 중...<//>`
  }

  if (kState.status === 'error') {
    return html`<${ErrorState} message=${kState.message} />`
  }
  if (rState.status === 'error') {
    return html`<${ErrorState} message=${rState.message} />`
  }
  if (cState.status === 'error') {
    return html`<${ErrorState} message=${cState.message} />`
  }
  if (mState.status === 'error') {
    return html`<${ErrorState} message=${mState.message} />`
  }

  if (kState.status !== 'loaded' || rState.status !== 'loaded' || cState.status !== 'loaded') {
    return null
  }

  const keepers = kState.data
  const repos = rState.data
  const credentials = cState.data.filter(credential => credential.type === 'github')
  const mappings = mState.status === 'loaded' ? mState.data : []
  const mappingByKeeper = new Map(mappings.map(m => [m.keeper_id, m]))

  const btnBase = 'py-1.5 px-4 rounded-[var(--r-1)] text-xs font-semibold cursor-pointer border-none'

  async function handleSave(keeperId: string) {
    const draft = draftMappings.value.get(keeperId)
    if (draft === undefined) return

    const payload = draft === '*' ? ['*'] : Array.from(draft)
    const credentialId = getDraftCredentialForKeeper(keeperId, null)
    savingKeeperId.value = keeperId
    saveError.value = null
    try {
      await saveKeeperRepos(keeperId, payload, credentialId)
      showToast('저장소 매핑 저장 완료', 'success')
      // Update the "original" mapping state so hasChanges resets
      await loadKeeperRepoMappings({ force: true })
    } catch (err) {
      const msg = err instanceof Error ? err.message : '저장 실패'
      saveError.value = msg
      showToast(msg, 'error')
    } finally {
      savingKeeperId.value = null
    }
  }

  function handleToggleRepo(keeperId: string, repoId: string) {
    const mapping = mappingByKeeper.get(keeperId)
    const original = mapping ? buildRepoSetFromMapping(mapping) : '*'
    const current = getDraftForKeeper(keeperId, original)
    const next = toggleRepo(keeperId, repoId, current)
    const nextMap = new Map(draftMappings.value)
    nextMap.set(keeperId, next)
    draftMappings.value = nextMap
  }

  function handleToggleAllowAll(keeperId: string) {
    const mapping = mappingByKeeper.get(keeperId)
    const original = mapping ? buildRepoSetFromMapping(mapping) : '*'
    const current = getDraftForKeeper(keeperId, original)
    const next = toggleAllowAll(keeperId, current)
    const nextMap = new Map(draftMappings.value)
    nextMap.set(keeperId, next)
    draftMappings.value = nextMap
  }

  function handleCredentialChange(keeperId: string, value: string) {
    const nextMap = new Map(draftCredentials.value)
    nextMap.set(keeperId, normalizeCredentialId(value))
    draftCredentials.value = nextMap
  }

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-bold text-text-strong">키퍼 저장소 매핑</h2>
        <button
          type="button"
          class="${btnBase} bg-[var(--white-10)] text-text-body"
          onClick=${() => loadKeeperRepoMappings({ force: true })}
        >
          새로고침
        </button>
      </div>

      ${saveError.value ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--color-status-err)]/30 bg-[var(--color-status-err)]/10 px-3 py-2 text-xs text-[var(--color-status-err)]" role="alert">
          ${saveError.value}
        </div>
      ` : null}

      ${keepers.length === 0 ? html`
        <div class="py-8 text-center text-2xs text-text-muted rounded-[var(--r-1)] border border-card-border/30 bg-card/10">
          등록된 키퍼가 없습니다.
        </div>
      ` : html`
        <div class="flex flex-col gap-3">
          ${keepers.map(keeper => {
            const keeperId = keeper.keeper_id ?? keeper.name
            const keeperName = keeper.name
            const mapping = mappingByKeeper.get(keeperId)
            const original = mapping ? buildRepoSetFromMapping(mapping) : '*'
            const draft = getDraftForKeeper(keeperId, original)
            const originalCredentialId = mapping ? buildCredentialIdFromMapping(mapping) : null
            const draftCredentialId = getDraftCredentialForKeeper(keeperId, originalCredentialId)
            const credentialOptions =
              draftCredentialId && !credentials.some(credential => credential.id === draftCredentialId)
                ? [
                    {
                      id: draftCredentialId,
                      name: `Missing: ${draftCredentialId}`,
                      type: 'github' as const,
                      username: draftCredentialId,
                      gh_config_dir: null,
                      state: null,
                    },
                    ...credentials,
                  ]
                : credentials
            const selectedCredential = draftCredentialId
              ? credentialOptions.find(credential => credential.id === draftCredentialId)
              : null
            const selectedLoginCommand = selectedCredential
              ? githubLoginCommand(selectedCredential.gh_config_dir)
              : null
            const allowAll = isAllowAll(keeperId, draft)
            const repoChanged = hasChanges(keeperId, original, draft)
            const credentialChanged = hasCredentialChange(keeperId, originalCredentialId, draftCredentialId)
            const changed = repoChanged || credentialChanged
            const isSaving = savingKeeperId.value === keeperId

            return html`
              <div
                key=${keeperId}
                class="rounded-[var(--r-1)] border border-card-border/50 bg-card/20 backdrop-blur-sm overflow-hidden shadow-[var(--shadow-1)]"
              >
                <div class="px-3 py-2.5 border-b border-card-border/30 bg-card/40 flex items-center justify-between gap-3">
                  <div class="flex items-center gap-2 min-w-0">
                    <span class="text-xs font-semibold text-text-strong truncate">${keeperName}</span>
                    ${keeper.agent_name ? html`
                      <span class="text-3xs text-text-dim font-mono truncate">${keeper.agent_name}</span>
                    ` : null}
                  </div>
                  <div class="flex items-center gap-2 shrink-0">
                    ${changed ? html`
                      <span class="text-3xs text-accent font-semibold">변경됨</span>
                    ` : null}
                    <button
                      type="button"
                      class="${btnBase} bg-[var(--color-status-ok)] text-[var(--color-fg-on-ok)] py-1 px-3 text-2xs"
                      onClick=${() => handleSave(keeperId)}
                      disabled=${isSaving || !changed}
                    >
                      ${isSaving ? '저장 중...' : '저장'}
                    </button>
                  </div>
                </div>

                <div class="p-3">
                  <div class="mb-3 rounded-[var(--r-1)] border border-card-border/40 bg-[var(--white-3)] px-2.5 py-2">
                    <div class="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
                      <label class="flex flex-col gap-1 min-w-0 md:min-w-[18rem]">
                        <span class="text-2xs font-bold uppercase tracking-wide text-text-muted">GitHub credential</span>
                        <select
                          class="rounded-[var(--r-1)] border border-card-border/60 bg-card px-2 py-1.5 text-xs text-text-body outline-none focus:border-accent"
                          value=${draftCredentialId ?? ''}
                          onChange=${(event: Event) => {
                            const target = event.currentTarget as HTMLSelectElement
                            handleCredentialChange(keeperId, target.value)
                          }}
                        >
                          <option value="">기본값: repo credential / local root</option>
                          ${credentialOptions.map(credential => html`
                            <option key=${credential.id} value=${credential.id}>
                              ${credential.name || credential.id} (${credential.username || credential.id})
                            </option>
                          `)}
                        </select>
                      </label>

                      <div class="flex flex-col gap-1 min-w-0 text-2xs text-text-muted md:items-end">
                        ${selectedCredential ? html`
                          <div class="flex items-center gap-1.5 min-w-0">
                            <span class="px-2 py-0.5 rounded-[var(--r-1)] border ${credentialStateBadgeClass(selectedCredential.state)}">
                              ${credentialStateLabel(selectedCredential.state)}
                            </span>
                            <span class="font-mono truncate">${selectedCredential.gh_config_dir ?? 'gh_config_dir 없음'}</span>
                          </div>
                          ${selectedLoginCommand ? html`
                            <code class="block max-w-full overflow-x-auto rounded-[var(--r-1)] bg-[var(--black-30)] px-2 py-1 font-mono text-3xs text-text-body">
                              ${selectedLoginCommand}
                            </code>
                          ` : null}
                        ` : html`
                          <span>직접 지정 없음</span>
                        `}
                      </div>
                    </div>
                  </div>

                  <label class="flex items-center gap-2 mb-3 cursor-pointer select-none">
                    <input
                      type="checkbox"
                      checked=${allowAll}
                      onChange=${() => handleToggleAllowAll(keeperId)}
                      class="accent-accent"
                    />
                    <span class="text-xs font-medium text-text-body">모든 저장소 허용 (*)</span>
                  </label>

                  ${repos.length === 0 ? html`
                    <div class="text-2xs text-text-muted py-2">사용 가능한 저장소가 없습니다.</div>
                  ` : html`
                    <div class="grid gap-1.5 ${repos.length > 6 ? 'grid-cols-2' : 'grid-cols-1'}">
                      ${repos.map(repo => {
                        const selected = isRepoSelected(keeperId, repo.id, draft)
                        return html`
                          <label
                            key="${keeperId}-${repo.id}"
                            class="flex items-center gap-2 rounded-[var(--r-1)] bg-[var(--white-3)] px-2 py-1.5 text-xs text-text-body cursor-pointer select-none hover:bg-[var(--white-5)] transition-colors"
                          >
                            <input
                              type="checkbox"
                              checked=${selected}
                              disabled=${allowAll}
                              onChange=${() => handleToggleRepo(keeperId, repo.id)}
                              class="accent-accent"
                            />
                            <span class="truncate ${allowAll ? 'opacity-50' : ''}">${repo.name}</span>
                            ${repo.url ? html`
                              <span class="text-3xs text-text-dim truncate ml-auto">${repo.url}</span>
                            ` : null}
                          </label>
                        `
                      })}
                    </div>
                  `}

                  ${!allowAll && draft !== '*' && (draft as Set<string>).size > 0 ? html`
                    <div class="mt-2 flex flex-wrap gap-1">
                      ${Array.from(draft as Set<string>).map(repoId => {
                        const repo = repos.find(r => r.id === repoId)
                        return html`<${RepoBadge} name=${repo?.name ?? repoId} />`
                      })}
                    </div>
                  ` : null}
                </div>
              </div>
            `
          })}
        </div>
      `}
    </div>
  `
}
