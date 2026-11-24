/**
 * Account → Admin-Only Members Lifecycle Tab.
 *
 * Wired to Stack A's `lib/auth/login_member_routes.mli`:
 * - `GET /api/v1/auth/members`
 * - `POST /api/v1/auth/members/:id/disable`
 * - `POST /api/v1/auth/members/:id/enable`
 * - `POST /api/v1/auth/members/:id/revoke-admin` (strict closed-sum `cause: 'security_incident' | 'operational'`)
 * - `DELETE /api/v1/auth/members/:id`
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect, useState } from 'preact/hooks'
import { pushShellToast } from '../../shell/shell-state'
import {
  REVOKE_ADMIN_CAUSES,
  deleteMember,
  disableMember,
  enableMember,
  formatIdentity,
  listMembers,
  revokeAdminMember,
  type MemberRecord,
  type RevokeAdminCause,
} from './wire'

const CAUSE_LABELS: Readonly<Record<RevokeAdminCause, string>> = Object.freeze({
  security_incident: 'security_incident — 보안 사고 대응',
  operational: 'operational — 운영 권한 조정',
})

export function MembersTab(): VNode {
  const [members, setMembers] = useState<readonly MemberRecord[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [busyUserId, setBusyUserId] = useState<string | null>(null)
  const [revokeTargetId, setRevokeTargetId] = useState<string | null>(null)
  const [revokeCause, setRevokeCause] = useState<RevokeAdminCause | ''>('')
  const [deleteTargetId, setDeleteTargetId] = useState<string | null>(null)

  const reload = async () => {
    setLoading(true)
    setError(null)
    const res = await listMembers()
    if (res.ok) {
      setMembers(res.value)
    } else if (res.error.kind !== 'epoch_stale' && res.error.kind !== 'aborted') {
      setError(res.error.message)
    }
    setLoading(false)
  }

  useEffect(() => {
    void reload()
  }, [])

  const runAction = async (userId: string, label: string, fn: () => Promise<{ readonly ok: boolean; readonly error?: { readonly message: string } }>) => {
    setBusyUserId(userId)
    setError(null)
    try {
      const res = await fn()
      if (!res.ok) {
        setError(res.error?.message ?? `${label} failed`)
        return
      }
      pushShellToast(`${label}: ${userId}`, 'success')
      setRevokeTargetId(null)
      setRevokeCause('')
      setDeleteTargetId(null)
      await reload()
    } finally {
      setBusyUserId(null)
    }
  }

  return html`
    <section class="ap-card" data-testid="account-members-tab">
      <header class="ap-card-head">
        <div>
          <h2 class="ap-card-title">Members & Admin Lifecycle (${members.length})</h2>
          <p class="ap-card-sub">
            Admin-only principal management. Server enforces the last-active-Admin invariant (HTTP 409) and requires an explicit closed-sum cause to revoke Admin privileges.
          </p>
        </div>
        <button type="button" class="btn-ghost" onClick=${() => { void reload() }}>Refresh</button>
      </header>

      ${error && html`<div class="ap-inline-alert ap-inline-alert--err" role="alert">${error}</div>`}

      ${loading
        ? html`<p class="ap-muted">구성원 목록을 불러오는 중…</p>`
        : members.length === 0
          ? html`<p class="ap-muted">등록된 구성원이 없습니다.</p>`
          : html`
              <ul class="ap-acct-list">
                ${members.map((member) => {
                  const busy = busyUserId === member.userId
                  const revoking = revokeTargetId === member.userId
                  const deleting = deleteTargetId === member.userId
                  return html`
                    <li key=${member.userId} class="ap-acct-row ap-acct-row--col" data-member-id=${member.userId}>
                      <div class="ap-acct-row-split">
                        <div>
                          <div class="ap-acct-row-top">
                            <code class="mono">${member.userId}</code>
                            <span class=${`ap-badge ap-badge--${member.role === 'admin' ? 'brass' : 'muted'}`}>
                              ${member.role}
                            </span>
                            <span class=${`ap-badge ap-badge--${member.status === 'active' ? 'ok' : 'warn'}`}>
                              ${member.status}
                            </span>
                            ${member.held.map((h) => html`
                              <span key=${h} class="ap-badge ap-badge--err">held:${h}</span>
                            `)}
                          </div>
                          <div class="ap-muted mono">${formatIdentity(member.identity)}</div>
                        </div>

                        <div class="ap-acct-actions">
                          ${member.status === 'active'
                            ? html`
                                <button
                                  type="button"
                                  class="btn-ghost"
                                  disabled=${busy}
                                  data-action="disable"
                                  onClick=${() => { void runAction(member.userId, 'Disable member', () => disableMember(member.userId)) }}
                                >
                                  Disable
                                </button>
                              `
                            : member.status === 'disabled'
                              ? html`
                                  <button
                                    type="button"
                                    class="btn-ghost"
                                    disabled=${busy}
                                    data-action="enable"
                                    onClick=${() => { void runAction(member.userId, 'Enable member', () => enableMember(member.userId)) }}
                                  >
                                    Enable
                                  </button>
                                `
                              : null}

                          ${member.role === 'admin' && html`
                            <button
                              type="button"
                              class="btn-ghost"
                              disabled=${busy}
                              data-action="open-revoke-admin"
                              onClick=${() => {
                                setDeleteTargetId(null)
                                setRevokeTargetId(revoking ? null : member.userId)
                                setRevokeCause('')
                              }}
                            >
                              Revoke Admin
                            </button>
                          `}

                          <button
                            type="button"
                            class="btn-ghost ap-danger-btn"
                            disabled=${busy}
                            data-action="open-delete"
                            onClick=${() => {
                              setRevokeTargetId(null)
                              setDeleteTargetId(deleting ? null : member.userId)
                            }}
                          >
                            Delete
                          </button>
                        </div>
                      </div>

                      ${revoking && html`
                        <form
                          class="ap-inline-panel"
                          data-testid="revoke-admin-form"
                          onSubmit=${(e: Event) => {
                            e.preventDefault()
                            if (revokeCause !== 'security_incident' && revokeCause !== 'operational') return
                            void runAction(member.userId, `Revoke Admin (${revokeCause})`, () => revokeAdminMember(member.userId, revokeCause))
                          }}
                        >
                          <label class="ap-field">
                            <span>Revocation Cause (required closed-sum)</span>
                            <select
                              class="ap-input"
                              required
                              aria-label="Admin 권한 회수 사유"
                              value=${revokeCause}
                              onChange=${(e: Event) => setRevokeCause((e.currentTarget as HTMLSelectElement).value as RevokeAdminCause | '')}
                            >
                              <option value="">사유를 선택하세요…</option>
                              ${REVOKE_ADMIN_CAUSES.map((c) => html`
                                <option key=${c} value=${c}>${CAUSE_LABELS[c]}</option>
                              `)}
                            </select>
                          </label>
                          <div class="ap-acct-actions">
                            <button
                              type="submit"
                              class="btn-primary"
                              disabled=${busy || (revokeCause !== 'security_incident' && revokeCause !== 'operational')}
                            >
                              Confirm Revoke Admin
                            </button>
                            <button type="button" class="btn-ghost" onClick=${() => { setRevokeTargetId(null); setRevokeCause('') }}>
                              Cancel
                            </button>
                          </div>
                        </form>
                      `}

                      ${deleting && html`
                        <div class="ap-inline-panel ap-inline-panel--err" data-testid="delete-member-confirm">
                          <span>
                            계정 <code class="mono">${member.userId}</code> 을(를) 영구 삭제합니다. 마지막 활성 Admin은 삭제할 수 없습니다.
                          </span>
                          <div class="ap-acct-actions">
                            <button
                              type="button"
                              class="btn-primary ap-danger-solid"
                              disabled=${busy}
                              onClick=${() => { void runAction(member.userId, 'Delete member', () => deleteMember(member.userId)) }}
                            >
                              Confirm Delete
                            </button>
                            <button type="button" class="btn-ghost" onClick=${() => setDeleteTargetId(null)}>
                              Cancel
                            </button>
                          </div>
                        </div>
                      `}
                    </li>
                  `
                })}
              </ul>
            `}
    </section>
  `
}
