import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import {
  clearStoredToken,
  currentDashboardActor,
  isRemoteAccess,
  setStoredToken,
} from '../api/core'
import { resetMcpClientState } from '../api/mcp'
import { dashboardAuthAccess } from '../lib/dashboard-auth-access'
import {
  hasDashboardActorQueryParam,
  readStoredDashboardActorName,
  resolveDashboardActorName,
  syncDashboardActorName,
} from '../lib/dashboard-actor'
import { refreshShell, shellAuthSummary } from '../store'
import { showToast } from './common/toast'

const popoverOpen = signal(false)
const tokenInput = signal('')
const actorInput = signal('')
const bannerDismissed = signal(false)

function cleanErrorMessage(value: string | null | undefined): string | null {
  if (!value) return null
  return value.replace(/^[^\w가-힣@]+/u, '').trim() || null
}

function mutationStatusLabel(allowed: boolean): string {
  return allowed ? '가능' : '차단'
}

function authBadgeSummary(): {
  dotColor: string
  label: string
} {
  const summary = shellAuthSummary.value
  const remote = isRemoteAccess()
  const validated = summary?.token_valid === true
  const role = summary?.effective_role ?? summary?.default_role ?? 'unknown'
  const actor = summary?.effective_agent ?? summary?.token_agent ?? currentDashboardActor()
  const hasError = summary?.auth_error_code != null || (summary?.token_present === true && !validated)

  if (validated) {
    return {
      dotColor: 'bg-[var(--color-status-ok)] shadow-[0_0_6px_rgba(74,222,128,0.6)]',
      label: `검증됨 @${actor} · ${role}`,
    }
  }
  if (hasError) {
    return {
      dotColor: 'bg-[var(--color-status-err)] shadow-[0_0_6px_rgba(244,63,94,0.45)]',
      label: '인증 오류',
    }
  }
  if (remote) {
    return {
      dotColor: 'bg-[var(--color-status-err)]',
      label: '미인증',
    }
  }
  return {
    dotColor: 'bg-[var(--color-status-warn)]',
    label: '로컬',
  }
}

async function refreshAuthTruth(): Promise<void> {
  await refreshShell({ force: true })
}

async function handleSetToken(): Promise<void> {
  const value = tokenInput.value.trim()
  if (!value) return
  setStoredToken(value, { source: 'manual' })
  resetMcpClientState()
  tokenInput.value = ''
  await refreshAuthTruth()
  const summary = shellAuthSummary.value
  popoverOpen.value = false
  if (summary?.token_valid) {
    const actor = summary.effective_agent ?? summary.token_agent ?? currentDashboardActor()
    const role = summary.effective_role ?? summary.default_role ?? 'unknown'
    showToast(`검증됨 @${actor} · ${role}`, 'success')
    return
  }
  showToast(
    cleanErrorMessage(summary?.auth_error_detail) ?? '토큰을 검증하지 못했습니다.',
    'error',
    6000,
  )
}

async function handleClearToken(): Promise<void> {
  clearStoredToken()
  resetMcpClientState()
  await refreshAuthTruth()
  popoverOpen.value = false
  const summary = shellAuthSummary.value
  const message = isRemoteAccess()
    ? cleanErrorMessage(summary?.auth_error_detail) ?? '토큰을 제거했습니다. 현재 미인증 상태입니다.'
    : '토큰을 제거했습니다. 현재 로컬 상태입니다.'
  showToast(message, 'warning')
}

async function handleApplyActor(): Promise<void> {
  if (shellAuthSummary.value?.token_valid) {
    showToast('검증된 세션은 token owner를 단일 actor로 사용합니다.', 'warning', 5000)
    return
  }
  const nextValue = actorInput.value.trim()
  if (!nextValue) return
  const normalized = syncDashboardActorName(nextValue, {
    rewriteQuery: hasDashboardActorQueryParam(),
  })
  actorInput.value = normalized
  resetMcpClientState()
  await refreshAuthTruth()
  const summary = shellAuthSummary.value
  const type = summary?.auth_error_code === 'actor_mismatch' ? 'warning' : 'success'
  const detail = cleanErrorMessage(summary?.auth_error_detail)
  showToast(detail ?? `actor를 @${normalized}로 설정했습니다.`, type, 5000)
}

function openPopover(): void {
  actorInput.value = resolveDashboardActorName() || 'dashboard'
  popoverOpen.value = true
}

function AuthRow({ label, value }: { label: string; value: string }) {
  return html`
    <div class="contents">
      <div class="text-[var(--color-fg-muted)]">${label}</div>
      <div class="text-[var(--color-fg-primary)] break-all">${value}</div>
    </div>
  `
}

export function AuthStatus() {
  const { dotColor, label } = authBadgeSummary()

  return html`
    <div class="relative">
      <button type="button"
        class="flex items-center gap-1.5 text-2xs py-1 px-2 rounded border border-solid border-[var(--color-border-default)] bg-[var(--white-4)] cursor-pointer font-[inherit] transition-colors duration-150 hover:bg-[var(--white-8)] text-[var(--color-fg-muted)]"
        onClick=${() => { popoverOpen.value ? (popoverOpen.value = false) : openPopover() }}
        title="인증 상태"
      >
        <span class="size-[7px] rounded-sm inline-block ${dotColor}"></span>
        <span>${label}</span>
      </button>
      ${popoverOpen.value ? html`<${AuthPopover} />` : null}
    </div>
  `
}

function AuthPopover() {
  const summary = shellAuthSummary.value
  const storedActor = readStoredDashboardActorName()
  const requestedActor = summary?.requested_agent ?? resolveDashboardActorName() ?? 'dashboard'
  const effectiveActor = summary?.effective_agent ?? summary?.token_agent ?? requestedActor
  const effectiveRole = summary?.effective_role ?? summary?.default_role ?? 'unknown'
  const mutationAccess = dashboardAuthAccess(summary, 'worker')
  const blockReason = cleanErrorMessage(summary?.auth_error_detail ?? summary?.keeper_msg_error ?? mutationAccess.reason)
    ?? '없음'
  const authenticated = summary?.token_valid === true
  const actorOverrideLocked = authenticated

  return html`
    <div class="absolute right-0 top-full mt-1.5 w-80 rounded border border-[var(--color-border-default)] bg-[rgba(10,18,34,0.97)] shadow-sm backdrop-blur-sm p-3 z-50">
      <div class="flex flex-col gap-3">
        <div class="grid grid-cols-[auto,1fr] gap-x-2 gap-y-1 text-2xs">
          <${AuthRow} label="stored actor" value=${storedActor ? `@${storedActor}` : '-'} />
          <${AuthRow} label="token owner" value=${summary?.token_agent ? `@${summary.token_agent}` : '-'} />
          <${AuthRow} label="effective actor" value=${effectiveActor ? `@${effectiveActor}` : '-'} />
          <${AuthRow} label="effective role" value=${effectiveRole} />
          <${AuthRow} label="mutation" value=${mutationStatusLabel(mutationAccess.allowed)} />
          <${AuthRow} label="block reason" value=${blockReason} />
        </div>

        <div class="flex flex-col gap-2">
          <div class="text-2xs text-[var(--color-fg-muted)]">행위자 재정의</div>
          ${actorOverrideLocked ? html`
            <div class="text-2xs text-[var(--color-fg-muted)]">
              검증된 세션은 token owner를 단일 actor로 사용합니다. 로컬 actor override는 저장되더라도 요청 actor로 쓰이지 않습니다.
            </div>
          ` : null}
          <div class="flex gap-2">
            <input
              type="text"
              placeholder="dashboard actor"
              aria-label="Dashboard actor"
              class="min-w-0 flex-1 py-1.5 px-2 rounded text-2xs border border-[var(--color-border-default)] bg-[var(--white-4)] text-[var(--color-fg-primary)] placeholder-[var(--color-fg-muted)] outline-none focus:border-[rgba(71,184,255,0.5)]"
              value=${actorInput.value}
              disabled=${actorOverrideLocked}
              onInput=${(e: Event) => { actorInput.value = (e.target as HTMLInputElement).value }}
              onKeyDown=${(e: KeyboardEvent) => {
                if (!actorOverrideLocked && e.key === 'Enter') void handleApplyActor()
              }}
            />
            <button type="button"
              class="shrink-0 py-1.5 px-3 rounded text-2xs border border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--color-accent-fg)] hover:bg-[var(--accent-15)] cursor-pointer transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              disabled=${actorOverrideLocked}
              onClick=${() => { void handleApplyActor() }}
            >적용</button>
          </div>
        </div>

        <div class="flex flex-col gap-2">
          <div class="text-2xs text-[var(--color-fg-muted)]">
            ${authenticated
              ? 'Bearer token이 서버에서 검증되었습니다.'
              : 'Bearer token을 입력하면 원격 환경에서 mutation 작업을 검증할 수 있습니다.'}
          </div>
          ${authenticated ? html`
            <button type="button"
              class="w-full py-1.5 px-3 rounded text-2xs border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--rose-light)] hover:bg-[var(--bad-soft)] cursor-pointer transition-colors"
              onClick=${() => { void handleClearToken() }}
            >토큰 제거</button>
          ` : html`
            <div class="flex flex-col gap-2">
              <input
                type="password"
                placeholder="Bearer token"
                aria-label="Bearer token"
                class="w-full py-1.5 px-2 rounded text-2xs border border-[var(--color-border-default)] bg-[var(--white-4)] text-[var(--color-fg-primary)] placeholder-[var(--color-fg-muted)] outline-none focus:border-[rgba(71,184,255,0.5)]"
                value=${tokenInput.value}
                onInput=${(e: Event) => { tokenInput.value = (e.target as HTMLInputElement).value }}
                onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') void handleSetToken() }}
              />
              <button type="button"
                class="w-full py-1.5 px-3 rounded text-2xs border border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--color-accent-fg)] hover:bg-[var(--accent-15)] cursor-pointer transition-colors"
                onClick=${() => { void handleSetToken() }}
              >토큰 설정</button>
            </div>
          `}
        </div>
      </div>
    </div>
  `
}

export function RemoteWarningBanner() {
  const summary = shellAuthSummary.value
  if (bannerDismissed.value || !isRemoteAccess() || summary?.token_valid) return null

  const message =
    summary?.auth_error_code === 'invalid_token' || summary?.auth_error_code === 'token_expired'
      ? '저장된 Bearer token이 검증되지 않았습니다. 새 토큰으로 교체하세요.'
      : summary?.auth_error_code === 'actor_mismatch'
        ? '토큰 owner와 dashboard actor가 달라 mutation 작업이 차단되었습니다. actor 또는 token을 정리하세요.'
        : '원격 접속이 감지되었습니다. Mutation 작업을 위해 검증된 Bearer token을 설정하세요.'

  return html`
    <div class="shrink-0 flex items-center justify-between gap-3 px-4 py-2 bg-[var(--warn-10)] border-b border-[var(--warn-20)] text-xs text-[var(--color-status-warn)]">
      <span>${message}</span>
      <div class="flex items-center gap-2 shrink-0">
        <button type="button"
          class="px-2 py-0.5 rounded text-2xs border border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--color-accent-fg)] hover:bg-[var(--accent-15)] cursor-pointer transition-colors"
          onClick=${openPopover}
        >인증 열기</button>
        <button type="button"
          class="text-[var(--color-fg-muted)] hover:text-[var(--color-fg-primary)] cursor-pointer text-2xs transition-colors"
          onClick=${() => { bannerDismissed.value = true }}
        >\u2715</button>
      </div>
    </div>
  `
}
