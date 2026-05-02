import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { useFocusScope } from '../../design-system/headless-preact/use-focus-scope'
import { useId } from '../../design-system/headless-preact/use-id'
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
import { TextInput } from './common/input'
import { KvRow } from './kv-row'
import { X } from 'lucide-preact'

const popoverOpen = signal(false)
const tokenInput = signal('')
const actorInput = signal('')
const bannerDismissed = signal(false)

// Test-only helper. Resets module-level signals so *.test.ts files can
// guarantee isolation in `beforeEach`. Mirrors use-id.ts:50 pattern.
export function __resetForTests(): void {
  popoverOpen.value = false
  tokenInput.value = ''
  actorInput.value = ''
  bannerDismissed.value = false
}

function cleanErrorMessage(value: string | null | undefined): string | null {
  if (!value) return null
  return value.replace(/^[^\w가-힣@]+/u, '').trim() || null
}

function mutationStatusLabel(allowed: boolean): string {
  return allowed ? 'Allowed' : 'Blocked'
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
      dotColor: 'bg-[var(--color-status-ok)] shadow-[0_0_6px_rgb(var(--ok-glow)/0.6)]',
      label: `Verified @${actor} · ${role}`,
    }
  }
  if (hasError) {
    return {
      dotColor: 'bg-[var(--color-status-err)] shadow-[0_0_6px_rgb(var(--err-glow)/0.45)]',
      label: 'Auth error',
    }
  }
  if (remote) {
    return {
      dotColor: 'bg-[var(--color-status-err)]',
      label: 'Unverified',
    }
  }
  return {
    dotColor: 'bg-[var(--color-status-warn)]',
    label: 'Local',
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
    showToast(`Verified @${actor} · ${role}`, 'success')
    return
  }
  showToast(
    cleanErrorMessage(summary?.auth_error_detail) ?? 'Failed to verify token.',
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
    ? cleanErrorMessage(summary?.auth_error_detail) ?? 'Token cleared; the session is now unverified.'
    : 'Token cleared; the session is now local.'
  showToast(message, 'warning')
}

async function handleApplyActor(): Promise<void> {
  if (shellAuthSummary.value?.token_valid) {
    showToast('Verified sessions use the token owner as the single actor.', 'warning', 5000)
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
  showToast(detail ?? `Dashboard actor set to @${normalized}.`, type, 5000)
}

function openPopover(): void {
  actorInput.value = resolveDashboardActorName() || 'dashboard'
  popoverOpen.value = true
}

export function AuthStatus() {
  const popoverId = useId()
  const labelId = useId()
  const { dotColor, label } = authBadgeSummary()

  return html`
    <div class="relative">
      <button type="button"
        class="flex items-center gap-1.5 text-2xs py-1 px-2 rounded-[var(--r-1)] border border-solid border-[var(--color-border-default)] bg-[var(--white-4)] cursor-pointer font-[inherit] transition-colors duration-150 hover:bg-[var(--white-8)] text-[var(--color-fg-muted)]"
        aria-expanded=${popoverOpen.value}
        aria-haspopup="true"
        aria-controls=${popoverId}
        onClick=${() => { popoverOpen.value ? (popoverOpen.value = false) : openPopover() }}
        title="Auth status"
        aria-label="Auth status"
      >
        <span class="size-[7px] rounded-[var(--r-0)] inline-block ${dotColor}"></span>
        <span>${label}</span>
      </button>
      ${popoverOpen.value ? html`<${AuthPopover} popoverId=${popoverId} labelId=${labelId} />` : null}
    </div>
  `
}

interface AuthPopoverProps {
  popoverId: string
  labelId: string
}

function AuthPopover({ popoverId, labelId }: AuthPopoverProps) {
  const panelRef = useRef<HTMLDivElement>(null)

  // Focus trap + restore: delegated to headless-core via useFocusScope.
  // RFC 0002 Iter 2 — Iter 1 (DialogOverlay PR #11827) is the canonical
  // reference; same shape as dialog.ts:48-55. AuthPopover is conditionally
  // mounted, so `active: true` while the component lives is sufficient —
  // unmount triggers the hook's cleanup which restores focus to the
  // element that was focused before the popover opened (the trigger button).
  useFocusScope({
    containerRef: panelRef,
    active: true,
    initialFocus: 'first',
  })

  // ESC closes the popover. Out of useFocusScope's scope per RFC 0001
  // §"out of scope" — handled inline so each popover can opt in/out of
  // close-on-ESC behavior independently.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        popoverOpen.value = false
      }
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [])

  const summary = shellAuthSummary.value
  const storedActor = readStoredDashboardActorName()
  const requestedActor = summary?.requested_agent ?? resolveDashboardActorName() ?? 'dashboard'
  const effectiveActor = summary?.effective_agent ?? summary?.token_agent ?? requestedActor
  const effectiveRole = summary?.effective_role ?? summary?.default_role ?? 'unknown'
  const mutationAccess = dashboardAuthAccess(summary, 'worker')
  const blockReason = cleanErrorMessage(summary?.auth_error_detail ?? summary?.keeper_msg_error ?? mutationAccess.reason)
    ?? 'None'
  const authenticated = summary?.token_valid === true
  const actorOverrideLocked = authenticated

  return html`
    <div
      ref=${panelRef}
      id=${popoverId}
      role="dialog"
      aria-labelledby=${labelId}
      data-state="open"
      class="auth-popover absolute right-0 top-full mt-1.5 w-80 rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] shadow-[var(--shadow-panel)] p-3 z-50"
    >
      <h2 id=${labelId} class="sr-only">Auth status panel</h2>
      <div class="flex flex-col gap-3">
        <div class="flex flex-col text-2xs">
          <${KvRow} label="stored actor" value=${storedActor ? `@${storedActor}` : '-'} wrap=${true} />
          <${KvRow} label="token owner" value=${summary?.token_agent ? `@${summary.token_agent}` : '-'} wrap=${true} />
          <${KvRow} label="effective actor" value=${effectiveActor ? `@${effectiveActor}` : '-'} wrap=${true} />
          <${KvRow} label="effective role" value=${effectiveRole} />
          <${KvRow} label="mutation" value=${mutationStatusLabel(mutationAccess.allowed)} />
          <${KvRow} label="block reason" value=${blockReason} wrap=${true} />
        </div>

        <div class="flex flex-col gap-2">
          <div class="text-2xs text-[var(--color-fg-muted)]">Actor override</div>
          ${actorOverrideLocked ? html`
            <div class="text-2xs text-[var(--color-fg-muted)]">
              Verified sessions use the token owner as the single actor. Local actor overrides are stored but not sent as the request actor.
            </div>
          ` : null}
          <div class="flex gap-2">
            <${TextInput}
              type="text"
              placeholder="Dashboard actor"
              ariaLabel="Dashboard actor"
              class="min-w-0 flex-1 !py-1.5 !px-2 !text-2xs"
              value=${actorInput.value}
              disabled=${actorOverrideLocked}
              onInput=${(e: Event) => { actorInput.value = (e.target as HTMLInputElement).value }}
              onKeyDown=${(e: KeyboardEvent) => {
                if (!actorOverrideLocked && e.key === 'Enter') void handleApplyActor()
              }}
            />
            <button type="button"
              class="shrink-0 py-1.5 px-3 rounded-[var(--r-1)] text-2xs border border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--color-accent-fg)] hover:bg-[var(--accent-15)] cursor-pointer transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              disabled=${actorOverrideLocked}
              onClick=${() => { void handleApplyActor() }}
            >Apply</button>
          </div>
        </div>

        <div class="flex flex-col gap-2">
          <div class="text-2xs text-[var(--color-fg-muted)]">
            ${authenticated
              ? 'Bearer token verified by the server.'
              : 'Enter a Bearer token to verify mutation work in remote environments.'}
          </div>
          ${authenticated ? html`
            <button type="button"
              class="w-full py-1.5 px-3 rounded-[var(--r-1)] text-2xs border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--rose-light)] hover:bg-[var(--bad-soft)] cursor-pointer transition-colors"
              onClick=${() => { void handleClearToken() }}
            >Clear token</button>
          ` : html`
            <div class="flex flex-col gap-2">
              <${TextInput}
                type="password"
                placeholder="Bearer token"
                ariaLabel="Bearer token"
                class="w-full !py-1.5 !px-2 !text-2xs"
                value=${tokenInput.value}
                onInput=${(e: Event) => { tokenInput.value = (e.target as HTMLInputElement).value }}
                onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') void handleSetToken() }}
              />
              <button type="button"
                class="w-full py-1.5 px-3 rounded-[var(--r-1)] text-2xs border border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--color-accent-fg)] hover:bg-[var(--accent-15)] cursor-pointer transition-colors"
                onClick=${() => { void handleSetToken() }}
              >Set token</button>
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
      ? 'Stored Bearer token is not verified. Replace it with a fresh token.'
      : summary?.auth_error_code === 'actor_mismatch'
        ? 'Token owner and dashboard actor differ, so mutations are blocked. Align the actor or token.'
        : 'Remote access detected. Set a verified Bearer token before running mutations.'

  return html`
    <div role="alert" class="shrink-0 flex items-center justify-between gap-3 px-4 py-2 bg-[var(--warn-10)] border-b border-[var(--warn-20)] text-xs text-[var(--color-status-warn)]">
      <span>${message}</span>
      <div class="flex items-center gap-2 shrink-0">
        <button type="button"
          class="px-2 py-0.5 rounded-[var(--r-1)] text-2xs border border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--color-accent-fg)] hover:bg-[var(--accent-15)] cursor-pointer transition-colors"
          aria-label="Open auth panel"
          onClick=${openPopover}
        >Open auth</button>
        <button type="button"
          class="flex size-6 items-center justify-center rounded-[var(--r-1)] text-[var(--color-fg-muted)] hover:bg-[var(--white-5)] hover:text-[var(--color-fg-primary)] cursor-pointer transition-colors"
          aria-label="Dismiss auth banner"
          onClick=${() => { bannerDismissed.value = true }}
        ><${X} size=${13} /><//>
      </div>
    </div>
  `
}
