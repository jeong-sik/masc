/**
 * Unified `/account` Workspace (Proposal A+ Multi-Account & Local Operator Surface).
 *
 * Exhaustively handles all 7 closed `AuthSession` states:
 * - `probing`: session boot status
 * - `multi_account_signed_out`: Google OIDC (`POST /auth/oidc/start`) & GitHub OAuth (`POST /auth/github/start`) sign-in gate
 * - `multi_account_signed_in`: Profile & Sessions, Personal Access Tokens, and Admin-only Members/Invites/Allowlist
 * - `account_changed`: cross-tab session-switch safety guard (sends zero mutations until reloaded)
 * - `single_user_local` / `single_user_auth_required`: Local Operator Bearer & Multi-Workspace Target manager
 * - `unavailable`: explicit error & retry bootstrap
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import {
  authSession,
  bootstrapAuthSession,
  type AuthSession,
} from '../../core/auth'
import { startObserverStream } from '../../core/observer'
import { isMobileViewport } from '../../shell/shell-state'
import type { WorkspaceViewProps } from '../types'
import { AllowlistTab } from './allowlist-tab'
import { InvitesTab } from './invites-tab'
import { LocalOperatorPanel } from './local-operator-panel'
import { MembersTab } from './members-tab'
import { PatsTab } from './pats-tab'
import { ProfileSessionsTab } from './profile-tab'

const ADMIN_TABS = new Set(['members', 'invites', 'allowlist'])

function ProviderSeparationNote({ onNavigate }: { readonly onNavigate: (path: string) => void }): VNode {
  return html`
    <p
      class="ap-muted"
      role="note"
      data-testid="account-provider-callout"
      style=${{
        margin: 0,
        display: 'flex',
        alignItems: 'center',
        gap: 'var(--sp-2)',
        flexWrap: 'wrap',
        fontSize: 'var(--fs-12)',
      }}
    >
      <span>Operator identity & workspace access — manage LLM Provider keys in</span>
      <button
        type="button"
        onClick=${() => onNavigate('/runtime/quotas')}
        style=${{
          padding: 0,
          border: 'none',
          background: 'transparent',
          color: 'var(--info-fg)',
          fontSize: 'var(--fs-12)',
          fontWeight: 500,
          textDecoration: 'underline',
          textUnderlineOffset: '2px',
          cursor: 'pointer',
        }}
      >
        Runtime → Quotas
      </button>
    </p>
  `
}

function MultiAccountSignInGate({
  session,
}: {
  readonly session: Extract<AuthSession, { readonly kind: 'multi_account_signed_out' }>
}): VNode {
  const { google, github } = session.authMethods
  const neither = !google && !github

  return html`
    <section class="ap-card ap-signin-gate" data-testid="multi-account-signin-gate">
      <header class="ap-card-head">
        <div>
          <span class="ap-eyebrow">MULTI-ACCOUNT SIGN IN</span>
          <h2 class="ap-card-title">Sign in to MASC</h2>
          <p class="ap-card-sub">
            Authenticate with your organization identity provider. Browser sessions use HttpOnly same-origin cookies + CSRF headers.
          </p>
        </div>
      </header>

      <div class="ap-signin-actions">
        ${(google || github) && html`
          <a
            href="/?return_to=%2Fdashboard%23account"
            class="btn-primary ap-signin-btn"
            data-testid="multi-account-signin-link"
            data-oauth-providers=${[google ? 'google' : '', github ? 'github' : ''].filter(Boolean).join(',')}
          >
            ${google && github
              ? 'Continue to Sign-In (Google / GitHub)'
              : google
                ? 'Continue to Google OIDC Sign-In'
                : 'Continue to GitHub OAuth Sign-In'}
          </a>
          <p class="ap-muted">
            Redirects to the server sign-in page (<code>/</code>) where OAuth form submission is permitted by strict CSP, then returns to <code>/dashboard#account</code>.
          </p>
        `}
        ${neither && html`
          <div class="ap-inline-alert ap-inline-alert--warn" role="alert">
            No OAuth provider (Google OIDC / GitHub) is enabled on this server&apos;s <code>/health</code> capabilities.
          </div>
        `}
      </div>
    </section>
  `
}

export function AccountWorkspace(props: WorkspaceViewProps): VNode {
  const session = authSession.value
  const mobile = isMobileViewport.value
  const activeTab = props.subroute || 'profile'

  return html`
    <div class="ap-workspace ap-account-workspace" data-testid="account-workspace">
      <header class="ap-workspace-head">
        <span class="ap-eyebrow">SYSTEM · OPERATOR IDENTITY</span>
        <h1 class="ap-workspace-title">Account & Workspace Access</h1>
        <${ProviderSeparationNote} onNavigate=${props.onNavigate} />
      </header>

      ${session.kind === 'probing' && html`
        <section class="ap-card" role="status">
          <p class="ap-muted">인증 및 서버 모드를 확인하는 중…</p>
        </section>
      `}

      ${session.kind === 'unavailable' && html`
        <section class="ap-card" role="alert" data-testid="account-unavailable">
          <h2 class="ap-card-title">Server Unavailable</h2>
          <p class="ap-muted">${session.reason}</p>
          <button
            type="button"
            class="btn-primary"
            onClick=${() => { void bootstrapAuthSession().then(() => startObserverStream()) }}
          >
            Retry Connection
          </button>
        </section>
      `}

      ${session.kind === 'account_changed' && html`
        <section class="ap-card ap-inline-panel--err" role="alert" data-testid="account-changed-banner">
          <h2 class="ap-card-title">다른 탭에서 계정이 변경되었습니다</h2>
          <p class="ap-card-sub">
            이전 계정(<code class="mono">${session.previousAccountId ?? '없음'}</code>)에서
            새 계정(<code class="mono">${session.nextAccountId ?? '로그아웃'}</code>)(으)로 세션이 바뀌었습니다.
            오동작 방지를 위해 이 탭의 모든 변경 요청이 중단되었습니다.
          </p>
          <button
            type="button"
            class="btn-primary"
            onClick=${() => { void bootstrapAuthSession().then(() => startObserverStream()) }}
          >
            현재 세션 다시 불러오기
          </button>
        </section>
      `}

      ${session.kind === 'multi_account_signed_out' && html`
        <${MultiAccountSignInGate} session=${session} />
      `}

      ${(session.kind === 'single_user_local' || session.kind === 'single_user_auth_required') && html`
        <${LocalOperatorPanel} session=${session} />
      `}

      ${session.kind === 'multi_account_signed_in' && (() => {
        const isAdmin = session.role === 'admin'
        const isAdminTab = ADMIN_TABS.has(activeTab)
        return html`
          ${mobile && html`
            <div class="ap-acct-tabs" role="tablist" aria-label="Account sections">
              ${([
                { id: 'profile', label: 'Profile & Sessions', adminOnly: false },
                { id: 'pats', label: 'Personal Access Tokens', adminOnly: false },
                { id: 'members', label: 'Members', adminOnly: true },
                { id: 'invites', label: 'Invites', adminOnly: true },
                { id: 'allowlist', label: 'Allowlist', adminOnly: true },
              ] as const).map((tab) => {
                const locked = tab.adminOnly && !isAdmin
                return html`
                  <button
                    key=${tab.id}
                    type="button"
                    role="tab"
                    aria-selected=${activeTab === tab.id ? 'true' : 'false'}
                    class=${`ap-acct-tab${activeTab === tab.id ? ' is-active' : ''}${locked ? ' is-locked' : ''}`}
                    data-rbac-locked=${locked ? 'true' : undefined}
                    onClick=${() => props.onNavigate(`/account/${tab.id}`)}
                  >
                    <span>${tab.label}</span>
                    ${locked && html`<span class="ap-acct-lock" aria-label="관리자 전용">🔒</span>`}
                  </button>
                `
              })}
            </div>
          `}

          ${isAdminTab && !isAdmin
            ? html`
                <section class="ap-card" role="status" data-testid="account-admin-locked">
                  <h2 class="ap-card-title">관리자 전용 영역</h2>
                  <p class="ap-muted">
                    현재 역할(<code class="mono">${session.role}</code>)은 <strong>${activeTab}</strong> 관리 권한이 없습니다.
                    권한 없는 API 요청은 전송하지 않습니다.
                  </p>
                  <button type="button" class="btn-ghost" onClick=${() => props.onNavigate('/account/profile')}>
                    Profile로 돌아가기
                  </button>
                </section>
              `
            : activeTab === 'pats'
              ? html`<${PatsTab} />`
              : activeTab === 'members'
                ? html`<${MembersTab} />`
                : activeTab === 'invites'
                  ? html`<${InvitesTab} />`
                  : activeTab === 'allowlist'
                    ? html`<${AllowlistTab} />`
                    : html`<${ProfileSessionsTab} session=${session} />`}
        `
      })()}
    </div>
  `
}

export default AccountWorkspace
