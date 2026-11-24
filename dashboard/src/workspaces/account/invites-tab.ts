/**
 * Account → Admin-Only Invitations Tab.
 * Wired to `GET/POST/DELETE /api/v1/auth/invites`.
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect, useState } from 'preact/hooks'
import { pushShellToast } from '../../shell/shell-state'
import {
  issueInvite,
  listInvites,
  revokeInvite,
  type InviteRecord,
  type InviteRole,
  type IssuedInvite,
} from './wire'

function formatInviteStatus(status: InviteRecord['status']): string {
  switch (status.kind) {
    case 'consumed': return `consumed (${status.joined})`
    default: return status.kind
  }
}

export function InvitesTab(): VNode {
  const [invites, setInvites] = useState<readonly InviteRecord[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [role, setRole] = useState<InviteRole>('member')
  const [issuing, setIssuing] = useState(false)
  const [issued, setIssued] = useState<IssuedInvite | null>(null)
  const [revokingId, setRevokingId] = useState<string | null>(null)

  const reload = async () => {
    setLoading(true)
    setError(null)
    const res = await listInvites()
    if (res.ok) setInvites(res.value)
    else if (res.error.kind !== 'epoch_stale' && res.error.kind !== 'aborted') {
      setError(res.error.message)
    }
    setLoading(false)
  }

  useEffect(() => {
    void reload()
    const onPageHide = () => setIssued(null)
    window.addEventListener('pagehide', onPageHide)
    return () => {
      window.removeEventListener('pagehide', onPageHide)
      setIssued(null)
    }
  }, [])

  const handleIssue = async (event: Event) => {
    event.preventDefault()
    if (issuing) return
    setIssuing(true)
    setError(null)
    try {
      const res = await issueInvite(role)
      if (!res.ok) {
        setError(res.error.message)
        return
      }
      setIssued(res.value)
      pushShellToast(`초대 링크가 생성되었습니다 (${role}).`, 'success')
      await reload()
    } finally {
      setIssuing(false)
    }
  }

  const handleRevoke = async (id: string) => {
    setRevokingId(id)
    try {
      const res = await revokeInvite(id)
      if (!res.ok) {
        setError(res.error.message)
        return
      }
      pushShellToast(`초대 취소 완료 (${id})`, 'info')
      await reload()
    } finally {
      setRevokingId(null)
    }
  }

  const fullInviteUrl = issued && typeof window !== 'undefined'
    ? new URL(issued.link, window.location.origin).href
    : issued?.link ?? ''

  return html`
    <div class="ap-acct-stack" data-testid="account-invites-tab">
      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Create Invitation</h2>
            <p class="ap-card-sub">
              One-time onboarding links for new Members or Admins. Token fragment is shown only once.
            </p>
          </div>
        </header>

        <form class="ap-form-row" onSubmit=${(e: Event) => { void handleIssue(e) }}>
          <label class="ap-field">
            <span>Role</span>
            <select
              class="ap-input"
              value=${role}
              onChange=${(e: Event) => setRole((e.currentTarget as HTMLSelectElement).value as InviteRole)}
            >
              <option value="member">Member (Worker)</option>
              <option value="admin">Admin</option>
            </select>
          </label>
          <button type="submit" class="btn-primary" disabled=${issuing}>
            ${issuing ? 'Creating…' : 'Create Invite Link'}
          </button>
        </form>

        ${issued && html`
          <div class="ap-secret-box" role="status" data-testid="issued-invite-link">
            <div class="ap-secret-head">
              <strong>One-time invite link (${issued.role})</strong>
              <button type="button" class="btn-ghost" onClick=${() => setIssued(null)}>Dismiss</button>
            </div>
            <div class="ap-secret-value">
              <code class="mono">${fullInviteUrl}</code>
              <button
                type="button"
                class="btn-primary"
                onClick=${() => {
                  void navigator.clipboard?.writeText(fullInviteUrl)
                  pushShellToast('초대 링크를 복사했습니다.', 'success')
                }}
              >
                Copy
              </button>
            </div>
          </div>
        `}
      </section>

      <section class="ap-card">
        <header class="ap-card-head">
          <h2 class="ap-card-title">Invitations (${invites.length})</h2>
          <button type="button" class="btn-ghost" onClick=${() => { void reload() }}>Refresh</button>
        </header>

        ${error && html`<div class="ap-inline-alert ap-inline-alert--err" role="alert">${error}</div>`}
        ${loading
          ? html`<p class="ap-muted">초대 목록을 불러오는 중…</p>`
          : invites.length === 0
            ? html`<p class="ap-muted">발급된 초대가 없습니다.</p>`
            : html`
                <ul class="ap-acct-list">
                  ${invites.map((inv) => {
                    const canRevoke = inv.status.kind === 'open' || inv.status.kind === 'revocation_pending'
                    return html`
                      <li key=${inv.id} class="ap-acct-row" data-invite-id=${inv.id}>
                        <div>
                          <div class="ap-acct-row-top">
                            <code class="mono">${inv.id}</code>
                            <span class=${`ap-badge ap-badge--${inv.role === 'admin' ? 'brass' : 'muted'}`}>
                              ${inv.role}
                            </span>
                            <span class=${`ap-badge ap-badge--${inv.status.kind === 'open' ? 'ok' : inv.status.kind === 'revocation_pending' ? 'warn' : 'muted'}`}>
                              ${formatInviteStatus(inv.status)}
                            </span>
                          </div>
                          <div class="ap-muted mono">
                            issuer: ${inv.issuer.kind === 'local_operator' ? 'local_operator' : inv.issuer.userId} ·
                            expires ${new Date(inv.expiresAtMs).toISOString().slice(0, 16).replace('T', ' ')}
                          </div>
                        </div>
                        ${canRevoke && html`
                          <button
                            type="button"
                            class="btn-ghost"
                            disabled=${revokingId === inv.id}
                            onClick=${() => { void handleRevoke(inv.id) }}
                          >
                            ${revokingId === inv.id ? 'Revoking…' : 'Revoke'}
                          </button>
                        `}
                      </li>
                    `
                  })}
                </ul>
              `}
      </section>
    </div>
  `
}
