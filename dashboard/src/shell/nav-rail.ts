/**
 * 6-Trunk Collapsible Labeled Rail (`Proposal A+` Locked Spec #30).
 *
 * - `[b]` toggle (`208px` expanded ↔ `56px` collapsed).
 * - Auto-collapses at `<=1440px` whenever Quick-Peek Drawer / Overlay opens.
 * - 6 L0 Trunks (`1 Pulse`, `2 Work`, `3 Knowledge`, `4 Keepers`, `5 Runtime`, `6 Infra`)
 *   + ONLY 2 Rail Footer anchors (`Settings [,]`, `Account`).
 * - Declarative RBAC gating: for `multi_account` non-Admin (`worker`/`viewer`), displays
 *   explicit lock signifiers (`data-rbac-locked="true"`) on Admin-only routes (`/infra/*`,
 *   `/settings`) without firing speculative 403 fetches.
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { authSession } from '../core/auth'
import {
  FOOTER_NAV,
  TRUNK_NAV,
  currentRoute,
  isAdminLockedForSession,
  navigate,
  type WorkspaceNavDef,
} from '../routes/router'
import { ShellIcon, type ShellIconName } from './icons'
import { inboxPendingCount, railExpanded, toggleRail } from './shell-state'

function iconForWorkspace(id: WorkspaceNavDef['id']): ShellIconName {
  return id
}

function renderNavItem(
  item: WorkspaceNavDef,
  activeWorkspace: string,
  expanded: boolean,
  pendingCount: number,
  locked: boolean,
): VNode {
  const isActive = activeWorkspace === item.id
  const badge = item.id === 'work' && pendingCount > 0 ? pendingCount : 0
  const tooltip = locked
    ? `${item.label} (관리자 전용)`
    : item.shortcut
      ? `${item.label} [${item.shortcut}]`
      : item.label

  return html`
    <a
      key=${item.id}
      href=${`#${item.defaultPath}`}
      class=${`ap-rail-item${isActive ? ' is-active' : ''}${locked ? ' is-locked' : ''}`}
      aria-current=${isActive ? 'page' : undefined}
      aria-label=${tooltip}
      title=${tooltip}
      data-nav-id=${item.id}
      data-rbac-locked=${locked ? 'true' : undefined}
      onClick=${(event: MouseEvent) => {
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
        event.preventDefault()
        navigate(item.defaultPath)
      }}
    >
      <span class="ap-rail-icon">
        <${ShellIcon} name=${iconForWorkspace(item.id)} size=${16} />
      </span>
      ${expanded && html`
        <span class="ap-rail-label">${item.label}</span>
      `}
      ${locked && html`
        <span class="ap-rail-lock" aria-label="관리자 전용" title="관리자 전용">
          <${ShellIcon} name="lock" size=${12} />
        </span>
      `}
      ${!locked && badge > 0 && html`
        <span class="ap-rail-badge tnum" aria-label=${`${badge}건 대기 중`}>${badge}</span>
      `}
      ${expanded && !locked && badge === 0 && item.shortcut && html`
        <kbd class="ap-rail-kbd">${item.shortcut}</kbd>
      `}
    </a>
  `
}

export function NavRail(): VNode {
  const expanded = railExpanded.value
  const route = currentRoute.value
  const session = authSession.value
  const pending = inboxPendingCount.value

  return html`
    <nav
      class="ap-rail"
      aria-label="주 탐색"
      data-expanded=${expanded ? 'true' : 'false'}
    >
      <div class="ap-rail-brand">
        <a
          href="#/pulse"
          class="ap-brand-link"
          aria-label="MASC 홈 (Pulse)"
          onClick=${(event: MouseEvent) => {
            if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
            event.preventDefault()
            navigate('/pulse')
          }}
        >
          <span class="ap-brand-mark" aria-hidden="true">M</span>
          ${expanded && html`<span class="ap-brand-name">MASC</span>`}
        </a>
        <button
          type="button"
          class="ap-rail-toggle"
          aria-label=${expanded ? '사이드바 접기 [b]' : '사이드바 펼치기 [b]'}
          aria-expanded=${expanded ? 'true' : 'false'}
          title=${expanded ? '사이드바 접기 [b]' : '사이드바 펼치기 [b]'}
          onClick=${toggleRail}
        >
          <${ShellIcon} name="sidebar" size=${15} />
        </button>
      </div>

      <div class="ap-rail-trunks" role="group" aria-label="워크스페이스">
        ${TRUNK_NAV.map((item) =>
          renderNavItem(
            item,
            route.workspace,
            expanded,
            pending,
            isAdminLockedForSession(item.access, session),
          ),
        )}
      </div>

      <div class="ap-rail-footer" role="group" aria-label="시스템">
        ${FOOTER_NAV.map((item) =>
          renderNavItem(
            item,
            route.workspace,
            expanded,
            0,
            isAdminLockedForSession(item.access, session),
          ),
        )}
      </div>
    </nav>
  `
}
