/**
 * Account → Admin-Only Sign-In Allowlist Tab.
 * Wired to `GET/POST/DELETE /api/v1/auth/allowlist`.
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect, useState } from 'preact/hooks'
import { pushShellToast } from '../../shell/shell-state'
import {
  GOOGLE_SUB_RE,
  formatIdentity,
  listAllowlist,
  registerAllowlist,
  removeAllowlist,
  type AllowlistEntry,
  type RegistrableIdentity,
} from './wire'

function formatStatus(status: AllowlistEntry['status']): string {
  return status.kind === 'consumed' ? `consumed (${status.joined})` : status.kind
}

export function AllowlistTab(): VNode {
  const [entries, setEntries] = useState<readonly AllowlistEntry[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [provider, setProvider] = useState<'google' | 'github'>('google')
  const [rawIdentifier, setRawIdentifier] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [removingId, setRemovingId] = useState<string | null>(null)

  const reload = async () => {
    setLoading(true)
    setError(null)
    const res = await listAllowlist()
    if (res.ok) setEntries(res.value)
    else if (res.error.kind !== 'epoch_stale' && res.error.kind !== 'aborted') {
      setError(res.error.message)
    }
    setLoading(false)
  }

  useEffect(() => {
    void reload()
  }, [])

  const handleRegister = async (event: Event) => {
    event.preventDefault()
    if (submitting) return
    const trimmed = rawIdentifier.trim()
    let identity: RegistrableIdentity
    if (provider === 'github') {
      const parsed = Number(trimmed)
      if (!Number.isSafeInteger(parsed) || parsed <= 0 || String(parsed) !== trimmed) {
        setError('GitHub user_id는 양의 정수여야 합니다.')
        return
      }
      identity = { provider: 'github', userId: parsed }
    } else {
      if (!GOOGLE_SUB_RE.test(trimmed)) {
        setError('Google sub는 공백 없는 1~255자 ASCII 문자열이어야 합니다.')
        return
      }
      identity = { provider: 'google', sub: trimmed }
    }

    setSubmitting(true)
    setError(null)
    try {
      const res = await registerAllowlist(identity)
      if (!res.ok) {
        setError(res.error.message)
        return
      }
      setRawIdentifier('')
      pushShellToast(
        res.value.previouslyDeleted
          ? '허용 목록 등록 완료 (이전 삭제 계정은 새 사용자로 재가입합니다).'
          : '허용 목록에 등록되었습니다.',
        'success',
      )
      await reload()
    } finally {
      setSubmitting(false)
    }
  }

  const handleRemove = async (id: string) => {
    setRemovingId(id)
    try {
      const res = await removeAllowlist(id)
      if (!res.ok) {
        setError(res.error.message)
        return
      }
      pushShellToast(`허용 목록 항목 제거 (${id})`, 'info')
      await reload()
    } finally {
      setRemovingId(null)
    }
  }

  return html`
    <div class="ap-acct-stack" data-testid="account-allowlist-tab">
      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Register Sign-In Allowlist Entry</h2>
            <p class="ap-card-sub">
              Pre-authorize a Google subject or GitHub numeric user ID to sign in directly as a Member.
            </p>
          </div>
        </header>

        <form class="ap-form-row" onSubmit=${(e: Event) => { void handleRegister(e) }}>
          <label class="ap-field">
            <span>Identity Provider</span>
            <select
              class="ap-input"
              value=${provider}
              onChange=${(e: Event) => {
                setProvider((e.currentTarget as HTMLSelectElement).value as 'google' | 'github')
                setRawIdentifier('')
                setError(null)
              }}
            >
              <option value="google">Google OIDC (sub)</option>
              <option value="github">GitHub OAuth (user_id)</option>
            </select>
          </label>

          <label class="ap-field ap-field--grow">
            <span>${provider === 'google' ? 'Google sub' : 'GitHub numeric user_id'}</span>
            <input
              type="text"
              class="ap-input mono"
              required
              placeholder=${provider === 'google' ? '109876543210987654321' : '1234567'}
              value=${rawIdentifier}
              onInput=${(e: Event) => setRawIdentifier((e.currentTarget as HTMLInputElement).value)}
            />
          </label>

          <button type="submit" class="btn-primary" disabled=${submitting}>
            ${submitting ? 'Registering…' : 'Register'}
          </button>
        </form>
      </section>

      <section class="ap-card">
        <header class="ap-card-head">
          <h2 class="ap-card-title">Allowlist Registrations (${entries.length})</h2>
          <button type="button" class="btn-ghost" onClick=${() => { void reload() }}>Refresh</button>
        </header>

        ${error && html`<div class="ap-inline-alert ap-inline-alert--err" role="alert">${error}</div>`}
        ${loading
          ? html`<p class="ap-muted">허용 목록을 불러오는 중…</p>`
          : entries.length === 0
            ? html`<p class="ap-muted">등록된 허용 목록 항목이 없습니다.</p>`
            : html`
                <ul class="ap-acct-list">
                  ${entries.map((entry) => {
                    const canRemove = entry.status.kind === 'open' || entry.status.kind === 'removal_pending'
                    return html`
                      <li key=${entry.id} class="ap-acct-row" data-allowlist-id=${entry.id}>
                        <div>
                          <div class="ap-acct-row-top">
                            <strong>${formatIdentity(entry.identity)}</strong>
                            <span class=${`ap-badge ap-badge--${entry.status.kind === 'open' ? 'ok' : entry.status.kind === 'removal_pending' ? 'warn' : 'muted'}`}>
                              ${formatStatus(entry.status)}
                            </span>
                          </div>
                          <div class="ap-muted mono">
                            id=${entry.id} · registrar=${entry.registrar}
                          </div>
                        </div>
                        ${canRemove && html`
                          <button
                            type="button"
                            class="btn-ghost"
                            disabled=${removingId === entry.id}
                            onClick=${() => { void handleRemove(entry.id) }}
                          >
                            ${removingId === entry.id ? 'Removing…' : 'Remove'}
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
