/**
 * Local Operator & Multi-Workspace Target Manager (`single_user_local` / `single_user_auth_required`).
 *
 * - Accepts manual Bearer token entry/rotation/clear (`setSingleUserToken` → bumps `sessionEpoch`).
 * - NEVER auto-probes `/api/v1/dashboard/dev-token` unless `/health` explicitly advertises
 *   `auth_methods.dev_token === true`.
 * - Manages registered MASC workspace targets (add/switch/remove).
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useState } from 'preact/hooks'
import {
  activeWorkspaceId,
  bootstrapAuthSession,
  registerWorkspaceTargets,
  selectWorkspace,
  sessionEpoch,
  setSingleUserToken,
  workspaceTargets,
  type AuthSession,
} from '../../core/auth'
import { startObserverStream } from '../../core/observer'
import { pushShellToast } from '../../shell/shell-state'

type SingleUserSession = Extract<
  AuthSession,
  { readonly kind: 'single_user_local' | 'single_user_auth_required' }
>

export function LocalOperatorPanel({
  session,
}: {
  readonly session: SingleUserSession
}): VNode {
  const [tokenInput, setTokenInput] = useState('')
  const [verifying, setVerifying] = useState(false)
  const [wsLabel, setWsLabel] = useState('')
  const [wsBaseUrl, setWsBaseUrl] = useState('')
  const [wsError, setWsError] = useState<string | null>(null)

  const targets = workspaceTargets.value
  const activeWs = activeWorkspaceId.value
  const epoch = sessionEpoch.value

  const handleApplyToken = async (event: Event) => {
    event.preventDefault()
    const trimmed = tokenInput.trim()
    setVerifying(true)
    try {
      setSingleUserToken(trimmed || null)
      setTokenInput('')
      const next = await bootstrapAuthSession()
      if (next.kind === 'single_user_local') {
        pushShellToast('Local Operator 인증이 확인되었습니다.', 'success')
        void startObserverStream()
      } else if (next.kind === 'single_user_auth_required') {
        pushShellToast(`인증 실패: ${next.reason}`, 'error')
      }
    } finally {
      setVerifying(false)
    }
  }

  const handleAddWorkspace = (event: Event) => {
    event.preventDefault()
    setWsError(null)
    const label = wsLabel.trim()
    const baseUrl = wsBaseUrl.trim()
    if (!label) {
      setWsError('워크스페이스 이름을 입력하세요.')
      return
    }
    let normalizedBaseUrl: string | undefined
    if (baseUrl) {
      if (/^\/(?!\/)/.test(baseUrl)) {
        normalizedBaseUrl = baseUrl.replace(/\/+$/, '') || '/'
      } else {
        try {
          const parsed = new URL(baseUrl)
          if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
            setWsError('동일 Origin의 http(s) URL 또는 상대 경로 접두사(예: /workspace-b)만 등록할 수 있습니다.')
            return
          }
          if (typeof window !== 'undefined' && window.location?.origin && parsed.origin !== window.location.origin) {
            setWsError('교차 출처(Cross-Origin) URL은 보안 정책상 차단됩니다. 동일 Origin URL 또는 상대 경로 접두사(/prefix)를 사용하세요.')
            return
          }
          normalizedBaseUrl = `${parsed.origin}${parsed.pathname.replace(/\/+$/, '')}`
        } catch {
          setWsError('올바른 경로 접두사(/workspace-b) 또는 동일 Origin URL을 입력하세요.')
          return
        }
      }
    }
    const slug = label.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-|-$/g, '') || `ws-${Date.now()}`
    const id = targets.some((t) => t.id === slug) ? `${slug}-${targets.length + 1}` : slug
    registerWorkspaceTargets([
      ...targets,
      { id, label, ...(normalizedBaseUrl ? { baseUrl: normalizedBaseUrl } : {}) },
    ])
    setWsLabel('')
    setWsBaseUrl('')
    pushShellToast(`워크스페이스 추가됨: ${label}`, 'success')
  }

  const handleRemoveWorkspace = (id: string) => {
    if (targets.length <= 1) return
    registerWorkspaceTargets(targets.filter((t) => t.id !== id))
    pushShellToast(`워크스페이스 제거됨 (${id})`, 'info')
  }

  return html`
    <div class="ap-acct-stack" data-testid="account-local-operator">
      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Local Operator & Bearer Access</h2>
            <p class="ap-card-sub">
              Single-user server mode. Accepts <code>?token=</code> from <code>masc login</code> (stripped from URL history) and keeps the bearer in tab-scoped sessionStorage (never localStorage).
            </p>
          </div>
          <span class=${`ap-badge ap-badge--${session.kind === 'single_user_local' ? 'ok' : 'warn'}`}>
            ${session.kind === 'single_user_local'
              ? session.tokenPresent ? 'Bearer Active' : 'Local Trusted'
              : 'Auth Required'}
          </span>
        </header>

        ${session.kind === 'single_user_auth_required' && html`
          <div class="ap-inline-alert ap-inline-alert--warn" role="alert">
            <div>${session.reason} — Paste an operator Bearer token below, or run in terminal:</div>
            <code class="mono">eval "$(masc login --agent local-dashboard-admin --role admin --client-env MASC_ADMIN_TOKEN --no-expiry --shell)" && open "$MASC_DASHBOARD_URL"</code>
          </div>
        `}

        <dl class="ap-kv-grid mono">
          <div><dt>Account Mode</dt><dd>single_user</dd></div>
          <div><dt>Dev-Token Advertised</dt><dd>${session.authMethods.dev_token ? 'true' : 'false (no probe)'}</dd></div>
          <div><dt>Active Workspace</dt><dd>${activeWs}</dd></div>
          <div><dt>Session Epoch</dt><dd class="tnum">${String(epoch)}</dd></div>
        </dl>

        <form class="ap-form-row" onSubmit=${(e: Event) => { void handleApplyToken(e) }}>
          <label class="ap-field ap-field--grow">
            <span>Operator Bearer Token</span>
            <input
              type="password"
              class="ap-input mono"
              placeholder="Paste MASC operator bearer token…"
              value=${tokenInput}
              onInput=${(e: Event) => setTokenInput((e.currentTarget as HTMLInputElement).value)}
            />
          </label>
          <button type="submit" class="btn-primary" disabled=${verifying}>
            ${verifying ? 'Verifying…' : 'Apply & Verify'}
          </button>
          ${session.kind === 'single_user_local' && session.tokenPresent && html`
            <button
              type="button"
              class="btn-ghost"
              onClick=${() => {
                setSingleUserToken(null)
                pushShellToast('Bearer 토큰이 제거되었습니다.', 'info')
              }}
            >
              Clear Token
            </button>
          `}
        </form>
      </section>

      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Multi-Workspace Targets (${targets.length})</h2>
            <p class="ap-card-sub">
              Register MASC server targets. Switching targets increments sessionEpoch and drops stale in-flight responses.
            </p>
          </div>
        </header>

        <ul class="ap-acct-list">
          ${targets.map((target) => {
            const isActive = target.id === activeWs
            return html`
              <li key=${target.id} class="ap-acct-row" data-ws-row=${target.id}>
                <div>
                  <strong>${target.label}</strong>
                  <div class="mono ap-muted">${target.baseUrl ?? 'same-origin'} · id=${target.id}</div>
                </div>
                <div class="ap-acct-actions">
                  <button
                    type="button"
                    class=${isActive ? 'btn-primary' : 'btn-ghost'}
                    disabled=${isActive}
                    onClick=${() => {
                      if (selectWorkspace(target.id)) {
                        pushShellToast(`워크스페이스 전환: ${target.label}`, 'info')
                        void startObserverStream()
                      }
                    }}
                  >
                    ${isActive ? 'Active' : 'Switch'}
                  </button>
                  ${targets.length > 1 && target.id !== 'default' && html`
                    <button
                      type="button"
                      class="btn-ghost"
                      onClick=${() => handleRemoveWorkspace(target.id)}
                    >
                      Remove
                    </button>
                  `}
                </div>
              </li>
            `
          })}
        </ul>

        <form class="ap-form-row" onSubmit=${handleAddWorkspace}>
          <label class="ap-field">
            <span>Workspace Label</span>
            <input
              type="text"
              class="ap-input"
              placeholder="e.g. Staging MASC"
              value=${wsLabel}
              onInput=${(e: Event) => setWsLabel((e.currentTarget as HTMLInputElement).value)}
            />
          </label>
          <label class="ap-field ap-field--grow">
            <span>Same-Origin Path Prefix or URL (optional)</span>
            <input
              type="text"
              class="ap-input mono"
              placeholder="/workspace-b"
              value=${wsBaseUrl}
              onInput=${(e: Event) => setWsBaseUrl((e.currentTarget as HTMLInputElement).value)}
            />
          </label>
          <button type="submit" class="btn-primary">Add Target</button>
        </form>
        ${wsError && html`<div class="ap-inline-alert ap-inline-alert--err" role="alert">${wsError}</div>`}
      </section>
    </div>
  `
}
