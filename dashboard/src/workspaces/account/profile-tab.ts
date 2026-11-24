/**
 * Account → Profile & Sessions tab (`multi_account_signed_in`).
 * Displays live `/api/v1/auth/whoami`, role badge, session epoch, sign-out, and workspace targets.
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect, useState } from 'preact/hooks'
import {
  activeWorkspaceId,
  bootstrapAuthSession,
  selectWorkspace,
  sessionEpoch,
  workspaceTargets,
  type AuthSession,
} from '../../core/auth'
import { startObserverStream } from '../../core/observer'
import { pushShellToast } from '../../shell/shell-state'
import { fetchWhoami, postLogout, type WhoamiInfo } from './wire'

type SignedInSession = Extract<AuthSession, { readonly kind: 'multi_account_signed_in' }>

export function ProfileSessionsTab({
  session,
}: {
  readonly session: SignedInSession
}): VNode {
  const [whoami, setWhoami] = useState<WhoamiInfo | null>(null)
  const [whoamiError, setWhoamiError] = useState<string | null>(null)
  const [signingOut, setSigningOut] = useState(false)
  const targets = workspaceTargets.value
  const activeWs = activeWorkspaceId.value
  const epoch = sessionEpoch.value

  useEffect(() => {
    let cancelled = false
    setWhoamiError(null)
    void fetchWhoami().then((res) => {
      if (cancelled) return
      if (res.ok) setWhoami(res.value)
      else if (res.error.kind !== 'epoch_stale' && res.error.kind !== 'aborted') {
        setWhoamiError(res.error.message)
      }
    })
    return () => { cancelled = true }
  }, [session.accountId, epoch])

  const handleSignOut = async () => {
    if (signingOut) return
    setSigningOut(true)
    try {
      const res = await postLogout()
      if (!res.ok && res.error.kind !== 'unauthorized') {
        pushShellToast(`로그아웃 실패: ${res.error.message}`, 'error')
        return
      }
      pushShellToast('로그아웃되었습니다.', 'info')
      await bootstrapAuthSession()
    } finally {
      setSigningOut(false)
    }
  }

  return html`
    <div class="ap-acct-stack" data-testid="account-profile-tab">
      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Profile & Active Browser Session</h2>
            <p class="ap-card-sub">
              Cookie-authenticated same-origin session with CSRF header protection (zero tokens stored in Web Storage).
            </p>
          </div>
          <button
            type="button"
            class="btn-ghost"
            disabled=${signingOut}
            onClick=${() => { void handleSignOut() }}
          >
            ${signingOut ? 'Signing out…' : 'Sign out'}
          </button>
        </header>

        <dl class="ap-kv-grid mono">
          <div><dt>Principal</dt><dd>${session.displayName}</dd></div>
          <div><dt>Account ID</dt><dd>${whoami?.id ?? session.accountId}</dd></div>
          <div><dt>Role</dt><dd>${session.role === 'admin' ? 'Admin' : session.role === 'worker' ? 'Worker (Member)' : 'Viewer'}</dd></div>
          <div><dt>Email</dt><dd>${session.email ?? '없음'}</dd></div>
          <div><dt>Session Epoch</dt><dd class="tnum">${String(epoch)}</dd></div>
          <div><dt>CSRF Guard</dt><dd>${session.csrfToken ? 'Active' : 'Missing'}</dd></div>
        </dl>

        ${whoamiError && html`
          <div class="ap-inline-alert ap-inline-alert--warn" role="alert">
            whoami 조회 실패: ${whoamiError}
          </div>
        `}
      </section>

      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Connected Workspace Targets</h2>
            <p class="ap-card-sub">
              Switching workspace increments the monotonic session epoch and drops stale in-flight fetches.
            </p>
          </div>
        </header>

        <ul class="ap-acct-list">
          ${targets.map((target) => {
            const active = target.id === activeWs
            return html`
              <li key=${target.id} class="ap-acct-row">
                <div>
                  <strong>${target.label}</strong>
                  <div class="mono ap-muted">${target.baseUrl ?? target.id}</div>
                </div>
                <button
                  type="button"
                  class=${active ? 'btn-primary' : 'btn-ghost'}
                  disabled=${active}
                  onClick=${() => {
                    if (selectWorkspace(target.id)) {
                      pushShellToast(`워크스페이스 전환: ${target.label}`, 'info')
                      void startObserverStream()
                    }
                  }}
                >
                  ${active ? 'Active' : 'Switch'}
                </button>
              </li>
            `
          })}
        </ul>
      </section>
    </div>
  `
}
