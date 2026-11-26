/**
 * Account → Personal Access Tokens (PATs) tab.
 * Wired to `GET/POST/DELETE /api/v1/auth/pats`.
 * Issued raw tokens are held strictly in ephemeral component memory and wiped on `pagehide` / unmount.
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect, useState } from 'preact/hooks'
import { copyToClipboard } from '../../components/common/copyable-code'
import { pushShellToast } from '../../shell/shell-state'
import {
  issuePat,
  listPats,
  revokePat,
  type IssuedPat,
  type PatRecord,
  type PatUsePreset,
} from './wire'

type ExpiryChoice = 'never' | '7d' | '30d' | '90d'

function computeExpiresAtMs(choice: ExpiryChoice): number | null {
  const dayMs = 86_400_000
  switch (choice) {
    case 'never': return null
    case '7d': return Date.now() + 7 * dayMs
    case '30d': return Date.now() + 30 * dayMs
    case '90d': return Date.now() + 90 * dayMs
  }
}

function formatDate(ms: number | null): string {
  if (ms === null) return '만료 없음'
  return new Date(ms).toISOString().slice(0, 16).replace('T', ' ')
}

export function PatsTab(): VNode {
  const [pats, setPats] = useState<readonly PatRecord[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [preset, setPreset] = useState<PatUsePreset>('read_only')
  const [expiry, setExpiry] = useState<ExpiryChoice>('30d')
  const [issuing, setIssuing] = useState(false)
  const [issued, setIssued] = useState<IssuedPat | null>(null)
  const [revokingId, setRevokingId] = useState<string | null>(null)

  const reload = async () => {
    setLoading(true)
    setError(null)
    const res = await listPats()
    if (res.ok) {
      setPats(res.value)
    } else if (res.error.kind !== 'epoch_stale' && res.error.kind !== 'aborted') {
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
      const res = await issuePat(preset, computeExpiresAtMs(expiry))
      if (!res.ok) {
        setError(res.error.message)
        return
      }
      setIssued(res.value)
      pushShellToast('새 Personal Access Token이 발급되었습니다.', 'success')
      await reload()
    } finally {
      setIssuing(false)
    }
  }

  const handleRevoke = async (id: string) => {
    setRevokingId(id)
    try {
      const res = await revokePat(id)
      if (!res.ok) {
        setError(res.error.message)
        return
      }
      pushShellToast(`토큰 폐기 완료 (${id})`, 'info')
      await reload()
    } finally {
      setRevokingId(null)
    }
  }

  return html`
    <div class="ap-acct-stack" data-testid="account-pats-tab">
      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Issue Personal Access Token</h2>
            <p class="ap-card-sub">
              Scoped bearer credentials for CLI / MCP clients. Raw secrets are shown once and never stored in browser storage.
            </p>
          </div>
        </header>

        <form class="ap-form-row" onSubmit=${(e: Event) => { void handleIssue(e) }}>
          <label class="ap-field">
            <span>Scope Preset</span>
            <select
              class="ap-input"
              value=${preset}
              onChange=${(e: Event) => setPreset((e.currentTarget as HTMLSelectElement).value as PatUsePreset)}
            >
              <option value="read_only">Read-Only (whoami & state)</option>
              <option value="mcp">MCP Full (Keeper turns, tools & own providers)</option>
            </select>
          </label>

          <label class="ap-field">
            <span>Expiration</span>
            <select
              class="ap-input"
              value=${expiry}
              onChange=${(e: Event) => setExpiry((e.currentTarget as HTMLSelectElement).value as ExpiryChoice)}
            >
              <option value="7d">7 days</option>
              <option value="30d">30 days</option>
              <option value="90d">90 days</option>
              <option value="never">No expiration</option>
            </select>
          </label>

          <button type="submit" class="btn-primary" disabled=${issuing}>
            ${issuing ? 'Issuing…' : 'Issue Token'}
          </button>
        </form>

        ${issued && html`
          <div class="ap-secret-box" role="status" data-testid="issued-pat-secret">
            <div class="ap-secret-head">
              <strong>One-time token issued (${issued.id}) — copy now; it cannot be shown again.</strong>
              <button type="button" class="btn-ghost" onClick=${() => setIssued(null)}>Dismiss</button>
            </div>
            <div class="ap-secret-value">
              <code class="mono">${issued.token}</code>
              <button
                type="button"
                class="btn-primary"
                onClick=${() => {
                  void copyToClipboard(issued.token).then((copied) => {
                    if (copied) {
                      pushShellToast('토큰을 클립보드에 복사했습니다.', 'success')
                    } else {
                      pushShellToast('클립보드 복사에 실패했습니다. 토큰을 직접 선택해 복사하세요.', 'error')
                    }
                  })
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
          <h2 class="ap-card-title">Issued Tokens (${pats.length})</h2>
          <button type="button" class="btn-ghost" onClick=${() => { void reload() }}>Refresh</button>
        </header>

        ${error && html`<div class="ap-inline-alert ap-inline-alert--err" role="alert">${error}</div>`}
        ${loading
          ? html`<p class="ap-muted">토큰 목록을 불러오는 중…</p>`
          : pats.length === 0
            ? html`<p class="ap-muted">발급된 Personal Access Token이 없습니다.</p>`
            : html`
                <ul class="ap-acct-list">
                  ${pats.map((pat) => html`
                    <li key=${pat.id} class="ap-acct-row" data-pat-id=${pat.id}>
                      <div>
                        <div class="ap-acct-row-top">
                          <code class="mono">${pat.id}</code>
                          <span class=${`ap-badge ap-badge--${pat.status === 'open' ? 'ok' : pat.status === 'revoked' ? 'err' : 'muted'}`}>
                            ${pat.status}
                          </span>
                        </div>
                        <div class="ap-muted mono">
                          issued ${formatDate(pat.issuedAtMs)} · expires ${formatDate(pat.expiresAtMs)}
                        </div>
                        <div class="ap-muted mono">
                          effects: ${pat.scope.effects === 'all' ? 'all' : pat.scope.effects.join(', ')}
                        </div>
                      </div>
                      ${pat.status === 'open' && html`
                        <button
                          type="button"
                          class="btn-ghost"
                          disabled=${revokingId === pat.id}
                          onClick=${() => { void handleRevoke(pat.id) }}
                        >
                          ${revokingId === pat.id ? 'Revoking…' : 'Revoke'}
                        </button>
                      `}
                    </li>
                  `)}
                </ul>
              `}
      </section>
    </div>
  `
}
