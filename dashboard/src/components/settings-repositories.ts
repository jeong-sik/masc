// Settings — Repositories section (keeper-v2 design settings.jsx `repositories`).
// Live-backed: GET/POST /api/v1/repositories, DELETE /api/v1/repositories/:id.
// Keeper-repo mapping is owned by Workspace › Repositories; this section links
// directly to that SSOT so Settings does not look incomplete.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import type { ComponentChildren } from 'preact'
import {
  addRepository,
  fetchRepositoriesList,
  removeRepository,
  type Repository,
} from '../api/repositories'
import { createAsyncResource } from '../lib/async-state'
import { requestConfirm } from './common/confirm-dialog'
import { showToast } from './common/toast'
import { errorMessageOr } from '../lib/format-string'
import { replaceRoute } from '../router'

const SYNC_INTERVAL_MIN_S = 60
const SYNC_INTERVAL_MAX_S = 3600
const SYNC_INTERVAL_STEP_S = 60
const DEFAULT_SYNC_INTERVAL_S = 300
const DEFAULT_BRANCH = 'main'

// ── State ────────────────────────────────────────────────

const reposResource = createAsyncResource<Repository[]>()
const reposState = reposResource.state

const formOpen = signal(false)
const formName = signal('')
const formUrl = signal('')
const formBranch = signal(DEFAULT_BRANCH)
const formPath = signal('')
const formAutoSync = signal(true)
const formInterval = signal(DEFAULT_SYNC_INTERVAL_S)
const formSubmitting = signal(false)
const formError = signal<string | null>(null)

function clampInterval(value: number): number {
  if (Number.isNaN(value)) return DEFAULT_SYNC_INTERVAL_S
  return Math.min(SYNC_INTERVAL_MAX_S, Math.max(SYNC_INTERVAL_MIN_S, value))
}

function resetForm(): void {
  formName.value = ''
  formUrl.value = ''
  formBranch.value = DEFAULT_BRANCH
  formPath.value = ''
  formAutoSync.value = true
  formInterval.value = DEFAULT_SYNC_INTERVAL_S
  formError.value = null
}

export async function refreshSettingsRepositories(): Promise<void> {
  await reposResource.load(() => fetchRepositoriesList())
}

export function _resetSettingsRepositoriesForTests(): void {
  formOpen.value = false
  resetForm()
}

// ── Actions ──────────────────────────────────────────────

async function submitAdd(): Promise<void> {
  if (formSubmitting.value) return
  const name = formName.value.trim()
  const url = formUrl.value.trim()
  if (!name || !url) return
  formSubmitting.value = true
  formError.value = null
  try {
    const localPath = formPath.value.trim()
    await addRepository({
      name,
      url,
      default_branch: formBranch.value.trim() || DEFAULT_BRANCH,
      auto_sync: formAutoSync.value,
      sync_interval: clampInterval(formInterval.value),
      ...(localPath ? { local_path: localPath } : {}),
    })
    showToast('저장소 등록 완료', 'success')
    formOpen.value = false
    resetForm()
    await refreshSettingsRepositories()
  } catch (err) {
    const msg = errorMessageOr(err, '저장소 등록 실패')
    formError.value = msg
    showToast(msg, 'error')
  } finally {
    formSubmitting.value = false
  }
}

async function deleteRepo(repo: Repository): Promise<void> {
  const confirmed = await requestConfirm({
    title: '저장소 제거',
    message: `${repo.name} 저장소 등록을 제거합니다. keeper 매핑과 동기화가 중단됩니다.`,
    confirmText: '제거',
    cancelText: '취소',
    tone: 'danger',
  })
  if (!confirmed) return
  try {
    await removeRepository(repo.id)
    showToast('저장소 제거 완료', 'success')
    await refreshSettingsRepositories()
  } catch (err) {
    showToast(errorMessageOr(err, '저장소 제거 실패'), 'error')
  }
}

function openKeeperRepoMappings(): void {
  replaceRoute('workspace', { section: 'repositories', view: 'mappings' })
}

// ── Local form primitives (design settings.jsx SetRow/SetToggle/SetStepper DOM) ──

function FormRow({ label, hint, children }: { label: string; hint?: string; children: ComponentChildren }) {
  return html`
    <div class="set-row">
      <div class="set-row-l">
        <div class="set-label">${label}</div>
        ${hint ? html`<div class="set-hint">${hint}</div>` : null}
      </div>
      <div class="set-row-c">${children}</div>
    </div>
  `
}

function AutoSyncToggle() {
  const on = formAutoSync.value
  return html`
    <button
      type="button"
      class=${`set-toggle${on ? ' on' : ''}`}
      role="switch"
      aria-checked=${on ? 'true' : 'false'}
      aria-label="자동 동기화"
      data-testid="settings-repo-autosync-toggle"
      disabled=${formSubmitting.value}
      onClick=${() => { formAutoSync.value = !formAutoSync.value }}
    >
      <span class="knob"></span>
    </button>
  `
}

function IntervalStepper() {
  const v = formInterval.value
  return html`
    <div class="set-stepper" data-testid="settings-repo-interval-stepper">
      <button
        type="button"
        aria-label="동기화 간격 감소"
        disabled=${formSubmitting.value}
        onClick=${() => { formInterval.value = clampInterval(v - SYNC_INTERVAL_STEP_S) }}
      >−</button>
      <span class="mono" data-testid="settings-repo-interval-value">${v}</span>
      <button
        type="button"
        aria-label="동기화 간격 증가"
        disabled=${formSubmitting.value}
        onClick=${() => { formInterval.value = clampInterval(v + SYNC_INTERVAL_STEP_S) }}
      >+</button>
    </div>
  `
}

function textInput(
  value: string,
  set: (next: string) => void,
  opts: { placeholder: string; width: number; testid: string },
) {
  return html`
    <input
      class="set-input mono"
      style=${{ width: `${opts.width}px` }}
      placeholder=${opts.placeholder}
      value=${value}
      data-testid=${opts.testid}
      disabled=${formSubmitting.value}
      onInput=${(e: Event) => { set((e.target as HTMLInputElement).value) }}
    />
  `
}

// ── Rows ─────────────────────────────────────────────────

function RepoRow({ repo }: { repo: Repository }) {
  return html`
    <div class="set-repo" data-testid="settings-repo-row" data-repo-id=${repo.id}>
      <div class="set-repo-main">
        <div class="set-repo-name mono">
          ${repo.name}
          <span class="set-repo-branch">${repo.default_branch}</span>
          ${repo.status === 'error'
            ? html`<span class="set-repo-branch" data-testid="settings-repo-status-error">오류</span>`
            : null}
          ${repo.status === 'unknown'
            ? html`<span class="set-repo-branch" data-testid="settings-repo-status-unknown">상태 미상</span>`
            : null}
        </div>
        <div class="set-repo-url mono">${repo.url || repo.local_path}</div>
      </div>
      <div class="set-repo-meta">
        <span class=${`set-repo-sync${repo.auto_sync ? ' on' : ''}`}>
          ${repo.auto_sync ? `자동 · ${repo.sync_interval}s` : '수동'}
        </span>
        <button
          type="button"
          class="set-repo-del"
          title="저장소 제거"
          aria-label=${`${repo.name} 저장소 제거`}
          onClick=${() => { void deleteRepo(repo) }}
        >✕</button>
      </div>
    </div>
  `
}

function AddForm() {
  const canSubmit = formName.value.trim().length > 0 && formUrl.value.trim().length > 0
  return html`
    <div class="set-repo-form" data-testid="settings-repo-form">
      <div class="set-sub-h">저장소 추가</div>
      ${formError.value
        ? html`<div class="set-hint" role="alert" data-testid="settings-repo-form-error">${formError.value}</div>`
        : null}
      <${FormRow} label="이름" hint="필수">
        ${textInput(formName.value, v => { formName.value = v }, { placeholder: 'my-project', width: 220, testid: 'settings-repo-name-input' })}
      <//>
      <${FormRow} label="URL" hint="필수 · git remote">
        ${textInput(formUrl.value, v => { formUrl.value = v }, { placeholder: 'https://github.com/owner/repo.git', width: 300, testid: 'settings-repo-url-input' })}
      <//>
      <${FormRow} label="기본 브랜치" hint="default_branch">
        ${textInput(formBranch.value, v => { formBranch.value = v }, { placeholder: DEFAULT_BRANCH, width: 160, testid: 'settings-repo-branch-input' })}
      <//>
      <${FormRow} label="로컬 경로" hint="비우면 .masc/repos/<id>">
        ${textInput(formPath.value, v => { formPath.value = v }, { placeholder: '.masc/repos/<id>', width: 260, testid: 'settings-repo-path-input' })}
      <//>
      <${FormRow} label="자동 동기화" hint="auto_sync">
        <${AutoSyncToggle} />
      <//>
      ${formAutoSync.value
        ? html`
          <${FormRow} label="동기화 간격" hint=${`초 · 최소 ${SYNC_INTERVAL_MIN_S}`}>
            <${IntervalStepper} />
          <//>
        `
        : null}
      <div class="set-repo-form-act">
        <button
          type="button"
          class="set-btn-ghost"
          data-testid="settings-repo-form-cancel"
          disabled=${formSubmitting.value}
          onClick=${() => { formOpen.value = false; resetForm() }}
        >취소</button>
        <button
          type="button"
          class="set-btn-primary"
          data-testid="settings-repo-form-submit"
          disabled=${!canSubmit || formSubmitting.value}
          onClick=${() => { void submitAdd() }}
        >${formSubmitting.value ? '등록 중…' : '저장소 등록'}</button>
      </div>
    </div>
  `
}

// ── Section ──────────────────────────────────────────────

export function SettingsRepositoriesSection() {
  const state = reposState.value
  if (state.status === 'idle') void refreshSettingsRepositories()

  return html`
    <div data-testid="settings-repositories-section">
      <div class="set-hint" style=${{ marginBottom: '12px' }}>
        keeper 가 작업하는 git 저장소. 등록하면 <span class="mono">POST /api/v1/repositories</span> 로
        클론되고, keeper 별 매핑은 워크스페이스 › Repositories 에서 관리합니다. 등록 기본 경로는
        <span class="mono">.masc/repos/${'<id>'}</span>, keeper 작업 clone 은 각 sandbox 의
        <span class="mono">repos/</span> 아래.
      </div>
      <div class="set-row" data-testid="settings-repo-mapping-entry">
        <div class="set-row-l">
          <div class="set-label">Keeper 접근</div>
          <div class="set-hint">명시 매핑은 선택 접근 필터입니다. 매핑이 없으면 keeper 개인 clone 기본 범위를 사용합니다.</div>
        </div>
        <div class="set-row-c">
          <button
            type="button"
            class="set-btn-ghost"
            data-testid="settings-repo-mapping-open"
            onClick=${openKeeperRepoMappings}
          >Keeper 접근 매핑 열기</button>
        </div>
      </div>

      ${state.status === 'loading'
        ? html`<div class="set-hint" data-testid="settings-repos-loading">저장소 목록 불러오는 중…</div>`
        : null}
      ${state.status === 'error'
        ? html`
          <div class="set-hint" role="alert" data-testid="settings-repos-error">
            저장소 목록을 불러오지 못했습니다: ${state.message}
            <button
              type="button"
              class="set-btn-ghost"
              style=${{ marginLeft: '8px' }}
              onClick=${() => { void refreshSettingsRepositories() }}
            >다시 시도</button>
          </div>
        `
        : null}

      ${state.status === 'loaded'
        ? html`
          <div class="set-repo-list" data-testid="settings-repo-list">
            ${state.data.length === 0
              ? html`<div class="set-hint" data-testid="settings-repos-empty">등록된 저장소 없음</div>`
              : state.data.map(repo => html`<${RepoRow} key=${repo.id} repo=${repo} />`)}
          </div>
        `
        : null}

      ${formOpen.value
        ? html`<${AddForm} />`
        : html`
          <button
            type="button"
            class="set-add"
            data-testid="settings-repo-add"
            onClick=${() => { resetForm(); formOpen.value = true }}
          >＋ 저장소 추가</button>
        `}
    </div>
  `
}
