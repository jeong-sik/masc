/**
 * Slim Proposal A+ Top Bar (`50px`).
 *
 * Left:   Vercel-style Account & Workspace Switcher (`[Avatar · @principal (role) / Workspace ▾]`)
 *         — zero conflation with LLM Providers; workspace switch calls `selectWorkspace()` (bumps `sessionEpoch`).
 * Center: L1 Sub-Tabs (max 5, strict 2-level cap) + Global `[24h | 7d | 30d]` Time-Window Pill
 *         (visible on telemetry routes `/pulse`, `/runtime/*`, `/knowledge/memory`, `/work/candle`).
 * Right:  TUI Top Rail parity pills: `[⌘K]`, honest Provenance pill (`● LIVE SSE | ◐ SYNCED | ○ SNAPSHOT | STREAM_GAP`
 *         with build-commit/connection popover — killing the permanent amber top banner!), `[Inbox (N)]`,
 *         `[⌘T Queue&Ctx]`, `[I Incidents]`.
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import {
  activeWorkspaceId,
  authSession,
  bootstrapAuthSession,
  isAuthenticated,
  selectWorkspace,
  sessionEpoch,
  setSingleUserToken,
  workspaceTargets,
  type AuthSession,
} from '../core/auth'
import {
  observerConnected,
  observerLastEventId,
  resolveObserverEndpoint,
  startObserverStream,
  viewProvenance,
  type ViewProvenance,
} from '../core/observer'
import { TIME_WINDOWS, setTimeWindow, timeWindow } from '../core/time-window'
import { apiMutate } from '../core/transport'
import {
  KEEPER_ENTITY_TAB_LABELS,
  KEEPER_ENTITY_TABS,
  WORKSPACE_NAV_BY_ID,
  currentRoute,
  isAdminLockedForSession,
  navigate,
} from '../routes/router'
import { PopoverMenu } from '../components/primitives/popover-menu'
import { ShellIcon } from './icons'
import {
  activeOverlay,
  buildConnectionInfo,
  formatInboxBadge,
  formatInboxPendingCount,
  inboxPendingCount,
  inboxUncheckedSources,
  isMobileViewport,
  openCommandPalette,
  probeBuildConnectionInfo,
  pushShellToast,
  toggleIncidentsOverlay,
  toggleQueueContextOverlay,
  unreadIncidentCount,
} from './shell-state'

function principalLabel(session: AuthSession): {
  readonly avatar: string
  readonly name: string
  readonly roleBadge: string | null
} {
  switch (session.kind) {
    case 'probing':
      return { avatar: '…', name: 'Checking session', roleBadge: null }
    case 'single_user_local':
      return {
        avatar: 'OP',
        name: 'Local Operator',
        roleBadge: session.tokenPresent ? 'Bearer' : 'Local',
      }
    case 'single_user_auth_required':
      return { avatar: '!', name: 'Auth Required', roleBadge: 'Token' }
    case 'multi_account_signed_out':
      return { avatar: '?', name: 'Sign In', roleBadge: 'Multi' }
    case 'multi_account_signed_in': {
      const cleaned = session.displayName.trim() || session.accountId
      const avatar = cleaned.replace(/[^a-zA-Z0-9]/g, '').slice(0, 2).toUpperCase() || 'AC'
      const roleBadge = session.role === 'admin'
        ? 'Admin'
        : session.role === 'worker'
          ? 'Worker'
          : 'Viewer'
      return { avatar, name: `@${cleaned}`, roleBadge }
    }
    case 'account_changed':
      return { avatar: '⇄', name: 'Account Changed', roleBadge: 'Reload' }
    case 'unavailable':
      return { avatar: '×', name: 'Offline', roleBadge: null }
  }
}

function effectiveProvenance(
  liveProv: ViewProvenance,
  connected: boolean,
  routeDefault: Exclude<ViewProvenance, 'STREAM_GAP'>,
): ViewProvenance {
  if (liveProv === 'STREAM_GAP') return 'STREAM_GAP'
  if (routeDefault === 'SNAPSHOT') return 'SNAPSHOT'
  if (routeDefault === 'LIVE SSE') {
    return connected ? 'LIVE SSE' : 'SNAPSHOT'
  }
  return connected ? 'SYNCED' : 'SNAPSHOT'
}

function provenanceMeta(prov: ViewProvenance): {
  readonly glyph: string
  readonly tone: 'live' | 'synced' | 'snapshot' | 'gap'
} {
  switch (prov) {
    case 'LIVE SSE':
      return { glyph: '●', tone: 'live' }
    case 'SYNCED':
      return { glyph: '◐', tone: 'synced' }
    case 'SNAPSHOT':
      return { glyph: '○', tone: 'snapshot' }
    case 'STREAM_GAP':
      return { glyph: '⚠', tone: 'gap' }
  }
}

function AccountWorkspaceSwitcher(): VNode {
  const [open, setOpen] = useState(false)
  const [bearerDraft, setBearerDraft] = useState('')
  const [signingOut, setSigningOut] = useState(false)
  const wrapRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)

  const session = authSession.value
  const targets = workspaceTargets.value
  const activeWsId = activeWorkspaceId.value
  const activeWs = targets.find((t) => t.id === activeWsId) ?? targets[0]
  const principal = principalLabel(session)

  useEffect(() => {
    if (!open) return
    const onOutside = (event: MouseEvent) => {
      if (wrapRef.current && !wrapRef.current.contains(event.target as Node)) {
        setOpen(false)
      }
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
      if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        setOpen(false)
        triggerRef.current?.focus?.()
      }
    }
    document.addEventListener('mousedown', onOutside)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onOutside)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  const handleMultiSignOut = async () => {
    if (signingOut) return
    setSigningOut(true)
    try {
      const res = await apiMutate('POST', '/auth/logout')
      if (!res.ok && res.error.kind !== 'unauthorized') {
        pushShellToast(`로그아웃 실패: ${res.error.message}`, 'error')
      } else {
        pushShellToast('로그아웃되었습니다.', 'info')
        await bootstrapAuthSession()
        setOpen(false)
        navigate('/account')
      }
    } finally {
      setSigningOut(false)
    }
  }

  const handleApplyBearer = (event: Event) => {
    event.preventDefault()
    const token = bearerDraft.trim()
    setSingleUserToken(token || null)
    setBearerDraft('')
    pushShellToast(token ? 'Bearer 토큰이 적용되었습니다.' : 'Bearer 토큰이 제거되었습니다.', 'success')
    void bootstrapAuthSession().then(() => startObserverStream())
    setOpen(false)
  }

  return html`
    <div class="ap-switcher-wrap" ref=${wrapRef}>
      <button
        ref=${triggerRef}
        type="button"
        class="ap-switcher-trigger"
        aria-haspopup="menu"
        aria-expanded=${open ? 'true' : 'false'}
        aria-label="계정 및 워크스페이스 전환"
        title=${`${principal.name} / ${activeWs?.label ?? activeWsId}`}
        data-testid="account-workspace-switcher"
        onClick=${() => setOpen((v) => !v)}
      >
        <span class="ap-switcher-avatar" aria-hidden="true">${principal.avatar}</span>
        <span class="ap-switcher-principal">${principal.name}</span>
        ${principal.roleBadge && html`
          <span class="ap-switcher-role">${principal.roleBadge}</span>
        `}
        <span class="ap-switcher-sep" aria-hidden="true">/</span>
        <span class="ap-switcher-ws">${activeWs?.label ?? activeWsId}</span>
        <${ShellIcon} name="chevron" size=${13} />
      </button>

      ${open && html`
        <div class="ap-popover ap-switcher-menu" role="menu" aria-label="계정 및 워크스페이스">
          <div class="ap-popover-section">
            <div class="ap-popover-eyebrow">OPERATOR IDENTITY</div>
            ${session.kind === 'multi_account_signed_in' && html`
              <div class="ap-switcher-identity-row">
                <div>
                  <div class="ap-switcher-id-name">${session.displayName}</div>
                  <div class="ap-switcher-id-sub mono">${session.accountId} · ${session.role}</div>
                </div>
                <button
                  type="button"
                  class="btn-ghost"
                  disabled=${signingOut}
                  onClick=${() => { void handleMultiSignOut() }}
                >
                  ${signingOut ? 'Signing out…' : 'Sign out'}
                </button>
              </div>
              <div class="ap-popover-links">
                <button
                  type="button"
                  class="ap-popover-item"
                  role="menuitem"
                  onClick=${() => { setOpen(false); navigate('/account/profile') }}
                >
                  Profile & Sessions
                </button>
                <button
                  type="button"
                  class="ap-popover-item"
                  role="menuitem"
                  onClick=${() => { setOpen(false); navigate('/account/pats') }}
                >
                  Personal Access Tokens (PATs)
                </button>
              </div>
            `}

            ${session.kind === 'multi_account_signed_out' && html`
              <div class="ap-switcher-oauth">
                ${(session.authMethods.google || session.authMethods.github) && html`
                  <a href="/" class="btn-primary ap-w-full" data-testid="switcher-signin-link">
                    Sign In (${[
                      session.authMethods.google ? 'Google' : '',
                      session.authMethods.github ? 'GitHub' : '',
                    ].filter(Boolean).join(' / ')})
                  </a>
                `}
                <button
                  type="button"
                  class="ap-popover-item"
                  onClick=${() => { setOpen(false); navigate('/account') }}
                >
                  Open Sign-In Gate →
                </button>
              </div>
            `}

            ${(session.kind === 'single_user_local' || session.kind === 'single_user_auth_required') && html`
              <form class="ap-switcher-bearer" onSubmit=${handleApplyBearer}>
                <label class="ap-switcher-label" for="ap-quick-bearer">
                  Local Operator Bearer Token
                </label>
                <div class="ap-switcher-bearer-row">
                  <input
                    id="ap-quick-bearer"
                    type="password"
                    class="ap-input"
                    placeholder=${session.kind === 'single_user_local' && session.tokenPresent ? 'Token active (enter to rotate)' : 'Paste Bearer token…'}
                    value=${bearerDraft}
                    onInput=${(e: Event) => setBearerDraft((e.currentTarget as HTMLInputElement).value)}
                  />
                  <button type="submit" class="btn-primary">Apply</button>
                </div>
                ${session.kind === 'single_user_local' && session.tokenPresent && html`
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${() => {
                      setSingleUserToken(null)
                      pushShellToast('Bearer 토큰이 해제되었습니다.', 'info')
                      setOpen(false)
                    }}
                  >
                    Clear Token
                  </button>
                `}
              </form>
            `}

            ${session.kind === 'account_changed' && html`
              <div class="ap-switcher-notice">
                다른 탭에서 계정이 변경되었습니다.
                <button
                  type="button"
                  class="btn-primary"
                  onClick=${() => {
                    setOpen(false)
                    void bootstrapAuthSession().then(() => startObserverStream())
                  }}
                >
                  Reload Session
                </button>
              </div>
            `}
          </div>

          <div class="ap-popover-section">
            <div class="ap-popover-eyebrow">WORKSPACE TARGET</div>
            <div class="ap-popover-links">
              ${targets.map((target) => {
                const selected = target.id === activeWsId
                return html`
                  <button
                    key=${target.id}
                    type="button"
                    role="menuitemradio"
                    aria-checked=${selected ? 'true' : 'false'}
                    class=${`ap-popover-item${selected ? ' is-selected' : ''}`}
                    data-workspace-target=${target.id}
                    onClick=${() => {
                      const changed = selectWorkspace(target.id)
                      setOpen(false)
                      if (changed) {
                        pushShellToast(`워크스페이스 전환: ${target.label}`, 'info')
                        void startObserverStream()
                      }
                    }}
                  >
                    <span>${target.label}</span>
                    <span class="mono ap-muted">${target.baseUrl ?? target.id}</span>
                  </button>
                `
              })}
            </div>
            <button
              type="button"
              class="ap-popover-item ap-popover-foot-action"
              onClick=${() => { setOpen(false); navigate('/account') }}
            >
              Manage Account & Workspaces →
            </button>
          </div>

          <div class="ap-popover-hint">
            Operator identity & workspace access — manage LLM Provider keys in Runtime → Quotas.
          </div>
        </div>
      `}
    </div>
  `
}

function ProvenancePill(): VNode {
  const [open, setOpen] = useState(false)
  const wrapRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)
  const route = currentRoute.value
  const liveProv = viewProvenance.value
  const connected = observerConnected.value
  const lastEventId = observerLastEventId.value
  const session = authSession.value
  const buildInfo = buildConnectionInfo.value
  const epoch = sessionEpoch.value

  const resolved = effectiveProvenance(liveProv, connected, route.defaultProvenance)
  const meta = provenanceMeta(resolved)
  const endpoint = resolveObserverEndpoint(session)

  useEffect(() => {
    if (!open) return
    const onOutside = (event: MouseEvent) => {
      if (wrapRef.current && !wrapRef.current.contains(event.target as Node)) {
        setOpen(false)
      }
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
      if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        setOpen(false)
        triggerRef.current?.focus?.()
      }
    }
    document.addEventListener('mousedown', onOutside)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onOutside)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  const provLabel = `연결 상태: ${resolved}${buildInfo.mismatched ? ' (빌드 커밋 불일치)' : ''}`

  return html`
    <div class="ap-prov-wrap" ref=${wrapRef}>
      <button
        ref=${triggerRef}
        type="button"
        class=${`ap-pill ap-pill--${meta.tone}`}
        aria-haspopup="dialog"
        aria-expanded=${open ? 'true' : 'false'}
        aria-label=${provLabel}
        title=${provLabel}
        data-testid="provenance-pill"
        data-provenance=${resolved}
        onClick=${() => {
          const next = !open
          setOpen(next)
          if (next) void probeBuildConnectionInfo()
        }}
      >
        <span class=${`ap-prov-glyph${meta.tone === 'live' ? ' is-live' : ''}`} aria-hidden="true">
          ${meta.glyph}
        </span>
        <span class="ap-prov-label">${resolved}</span>
        ${buildInfo.mismatched && html`
          <span class="ap-prov-drift-dot" title="서버와 대시보드 빌드 커밋이 다릅니다" aria-hidden="true">•</span>
        `}
      </button>

      ${open && html`
        <div class="ap-popover ap-prov-popover" role="dialog" aria-label="연결 및 빌드 상태">
          <div class="ap-popover-eyebrow">CONNECTION & PROVENANCE</div>
          <dl class="ap-kv-list mono">
            <div><dt>Provenance</dt><dd>${resolved}</dd></div>
            <div><dt>Observer</dt><dd>${endpoint?.url ?? 'idle'}</dd></div>
            <div><dt>Last-Event-ID</dt><dd>${lastEventId ?? '없음'}</dd></div>
            <div><dt>Session Epoch</dt><dd>${String(epoch)}</dd></div>
            <div><dt>Server Version</dt><dd>${buildInfo.version ?? '미보고'}</dd></div>
            <div><dt>Server Commit</dt><dd>${buildInfo.serverCommit?.slice(0, 10) ?? '미보고'}</dd></div>
            <div><dt>Bundle Commit</dt><dd>${buildInfo.bundleCommit?.slice(0, 10) ?? '미보고'}</dd></div>
          </dl>
          ${buildInfo.mismatched && html`
            <div class="ap-prov-mismatch" role="status">
              서버 빌드 커밋과 대시보드 번들이 다릅니다. 새로고침하거나 번들을 다시 빌드하세요.
            </div>
          `}
          <div class="ap-prov-actions">
            <button
              type="button"
              class="btn-ghost"
              onClick=${() => {
                void startObserverStream()
                void probeBuildConnectionInfo()
              }}
            >
              <${ShellIcon} name="refresh" size=${13} />
              Reconnect SSE
            </button>
          </div>
        </div>
      `}
    </div>
  `
}

export function TopBar(): VNode {
  const route = currentRoute.value
  const session = authSession.value
  const navDef = WORKSPACE_NAV_BY_ID[route.workspace]
  const mobile = isMobileViewport.value
  const pending = inboxPendingCount.value
  const pendingUnchecked = isAuthenticated.value && inboxUncheckedSources.value.length > 0
  const pendingLabel = pendingUnchecked ? formatInboxPendingCount(pending, true) : `${pending}건 대기`
  const formattedBadge = formatInboxBadge(pending, pendingUnchecked)
  const pendingBadge = formattedBadge ?? '0'
  const unreadInc = unreadIncidentCount.value
  const overlay = activeOverlay.value
  const win = timeWindow.value

  // L1 sub-tabs: workspace subtabs (max 5) OR Keeper entity tabs when on `/keepers/:name/*`
  const subtabs = route.workspace === 'keepers' && route.entityId
    ? KEEPER_ENTITY_TABS.map((tab) => ({
        id: tab,
        label: KEEPER_ENTITY_TAB_LABELS[tab],
        path: `/keepers/${encodeURIComponent(route.entityId!)}/${tab}`,
        active: route.entityTab === tab,
        locked: false,
      }))
    : navDef.subtabs.map((tab) => ({
        id: tab.id,
        label: tab.label,
        path: tab.path,
        active: route.subroute === tab.id,
        locked: isAdminLockedForSession(tab.access, session),
      }))

  const renderSubtabLink = (tab: (typeof subtabs)[number]) => {
    const subtabBadge = route.workspace === 'work' && tab.id === 'inbox'
      ? formattedBadge
      : null
    return html`
      <a
        key=${tab.id}
        href=${`#${tab.path}`}
        class=${`ap-subtab${tab.active ? ' is-active' : ''}${tab.locked ? ' is-locked' : ''}`}
        aria-current=${tab.active ? 'page' : undefined}
        aria-label=${subtabBadge !== null ? `${tab.label} (${pendingLabel})` : undefined}
        data-subtab=${tab.id}
        data-rbac-locked=${tab.locked ? 'true' : undefined}
        onClick=${(event: MouseEvent) => {
          if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
          event.preventDefault()
          navigate(tab.path)
        }}
      >
        <span>${tab.label}</span>
        ${subtabBadge !== null && html`
          <span
            class="ap-subtab-badge tnum"
            data-testid="subtab-inbox-badge"
            aria-hidden="true"
            title=${pendingLabel}
          >${subtabBadge}</span>
        `}
        ${tab.locked && html`<${ShellIcon} name="lock" size=${11} />`}
      </a>
    `
  }

  return html`
    <header class="ap-topbar" role="banner">
      <div class="ap-topbar-left">
        <${AccountWorkspaceSwitcher} />
      </div>

      ${!mobile && subtabs.length > 0 && html`
        <nav class="ap-subtabs" aria-label=${`${navDef.label} 하위 탭`}>
          ${subtabs.map(renderSubtabLink)}
        </nav>
      `}

      <div class="ap-topbar-right">
        ${route.supportsTimeWindow && (mobile
          ? html`
              <${PopoverMenu}
                triggerLabel=${html`<span class="tnum">${win}</span>`}
                triggerIcon=${html`<${ShellIcon} name="chevron" size=${11} />`}
                triggerClassName="ap-pill ap-win-compact-trigger"
                triggerTestId="time-window-pill"
                popoverTestId="time-window-menu"
                align="right"
                ariaLabel=${`시간 창 선택 (${win})`}
                items=${TIME_WINDOWS.map((w) => ({
                  id: w,
                  label: w,
                  active: win === w,
                  testId: `time-window-option-${w}`,
                  onSelect: () => setTimeWindow(w),
                }))}
              />
            `
          : html`
              <div class="ap-win-group" role="group" aria-label="시간 창 선택" data-testid="time-window-pill">
                ${TIME_WINDOWS.map((w) => html`
                  <button
                    key=${w}
                    type="button"
                    class=${`ap-win-btn tnum${win === w ? ' is-active' : ''}`}
                    aria-pressed=${win === w ? 'true' : 'false'}
                    onClick=${() => setTimeWindow(w)}
                  >
                    ${w}
                  </button>
                `)}
              </div>
            `)}

        <button
          type="button"
          class="ap-pill"
          aria-label="명령 팔레트 열기 (⌘K)"
          title="명령 팔레트 열기 (⌘K)"
          data-testid="cmdk-trigger"
          onClick=${openCommandPalette}
        >
          <${ShellIcon} name="search" size=${13} />
          <kbd class="ap-kbd">⌘K</kbd>
        </button>

        <${ProvenancePill} />

        ${!mobile && html`
          <button
            type="button"
            class=${`ap-pill${pending > 0 || pendingUnchecked ? ' ap-pill--warn' : ''}`}
            aria-label=${`Inbox (${pendingLabel})`}
            title=${`Inbox (${pendingLabel})`}
            data-testid="inbox-pill"
            onClick=${() => navigate('/work/inbox')}
          >
            <${ShellIcon} name="inbox" size=${13} />
            <span class="ap-pill-label">Inbox</span>
            <span class="ap-pill-count tnum" title=${pendingLabel}>${pendingBadge}</span>
          </button>

          <button
            type="button"
            class=${`ap-pill${overlay?.kind === 'queue_context' ? ' is-active' : ''}`}
            aria-pressed=${overlay?.kind === 'queue_context' ? 'true' : 'false'}
            aria-label="Queue & Context 빠른 보기 (⌘T)"
            title="Queue & Context 빠른 보기 (⌘T)"
            data-testid="queue-ctx-pill"
            onClick=${toggleQueueContextOverlay}
          >
            <${ShellIcon} name="layers" size=${13} />
            <kbd class="ap-kbd">⌘T</kbd>
          </button>

          <button
            type="button"
            class=${`ap-pill${overlay?.kind === 'incidents' ? ' is-active' : ''}${unreadInc > 0 ? ' ap-pill--err' : ''}`}
            aria-pressed=${overlay?.kind === 'incidents' ? 'true' : 'false'}
            aria-label=${`Incidents 빠른 보기 [I] (읽지 않음 ${unreadInc}건)`}
            title=${`Incidents 빠른 보기 [I] (읽지 않음 ${unreadInc}건)`}
            data-testid="incidents-pill"
            onClick=${toggleIncidentsOverlay}
          >
            <${ShellIcon} name="bell" size=${13} />
            <kbd class="ap-kbd">I</kbd>
            ${unreadInc > 0 && html`<span class="ap-pill-count tnum">${unreadInc}</span>`}
          </button>
        `}
      </div>
    </header>
    ${mobile && subtabs.length > 0 && html`
      <nav
        class="ap-mobile-subtabs"
        aria-label=${`${navDef.label} 하위 탭`}
        data-testid="mobile-subtabs"
      >
        ${subtabs.map(renderSubtabLink)}
      </nav>
    `}
  `
}
