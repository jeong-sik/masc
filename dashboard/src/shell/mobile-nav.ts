/**
 * Mobile Navigation (`<768px`): 4-Tab Bottom Bar + `More` Sheet.
 *
 * - Primary 4 tabs: `Pulse`, `Work`, `Keepers`, `Runtime` + `More` button (all `>=44px` touch targets).
 * - `More` sheet exposes `Knowledge`, `Infra` (RBAC-locked for non-admin), `Settings` (RBAC-locked),
 *   `Account`, `Queue & Context`, `Incidents`, and `Command Palette`.
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect, useRef } from 'preact/hooks'
import { useFocusScope } from '../../design-system/headless-preact/use-focus-scope'
import { authSession, isAuthenticated } from '../core/auth'
import {
  WORKSPACE_NAV_BY_ID,
  currentRoute,
  isAdminLockedForSession,
  navigate,
} from '../routes/router'
import type { WorkspaceId } from '../workspaces/types'
import { ShellIcon, type ShellIconName } from './icons'
import {
  formatInboxBadge,
  formatInboxPendingCount,
  inboxPendingCount,
  inboxUncheckedSources,
  mobileMoreOpen,
  openCommandPalette,
  toggleIncidentsOverlay,
  toggleQueueContextOverlay,
  unreadIncidentCount,
} from './shell-state'

const MOBILE_PRIMARY_TABS: readonly WorkspaceId[] = ['pulse', 'work', 'keepers', 'runtime']
const MOBILE_MORE_WORKSPACES: readonly WorkspaceId[] = ['knowledge', 'infra', 'settings', 'account']

export function MobileNav(): VNode {
  const route = currentRoute.value
  const session = authSession.value
  const moreOpen = mobileMoreOpen.value
  const pending = inboxPendingCount.value
  const pendingUnchecked = isAuthenticated.value && inboxUncheckedSources.value.length > 0
  const workBadge = formatInboxBadge(pending, pendingUnchecked)
  const workBadgeLabel = pendingUnchecked
    ? `Inbox ${formatInboxPendingCount(pending, true)}`
    : `Inbox ${pending}건 대기 중`
  const unreadInc = unreadIncidentCount.value
  const sheetRef = useRef<HTMLDivElement>(null)

  useFocusScope({ containerRef: sheetRef, active: moreOpen })

  useEffect(() => {
    if (!moreOpen) return
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
      if (event.key === 'Escape') {
        if (typeof document !== 'undefined') {
          const otherModalOpen = Array.from(
            document.querySelectorAll('[role="dialog"][aria-modal="true"]'),
          ).some((el) => el !== sheetRef.current)
          if (otherModalOpen) return
        }
        event.preventDefault()
        event.stopPropagation()
        mobileMoreOpen.value = false
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [moreOpen])

  const inMore = MOBILE_MORE_WORKSPACES.includes(route.workspace)

  return html`
    ${moreOpen && html`
      <div
        class="ap-sheet-backdrop"
        aria-hidden="true"
        onClick=${() => { mobileMoreOpen.value = false }}
      />
      <div
        ref=${sheetRef}
        class="ap-more-sheet"
        role="dialog"
        aria-modal="true"
        aria-label="더 보기 메뉴"
        data-testid="mobile-more-sheet"
      >
        <div class="ap-more-head">
          <strong>More</strong>
          <button
            type="button"
            class="btn-ghost ap-touch-target"
            aria-label="닫기"
            onClick=${() => { mobileMoreOpen.value = false }}
          >
            <${ShellIcon} name="x" size=${16} />
          </button>
        </div>

        <div class="ap-more-grid">
          ${MOBILE_MORE_WORKSPACES.map((id) => {
            const def = WORKSPACE_NAV_BY_ID[id]
            const locked = isAdminLockedForSession(def.access, session)
            const active = route.workspace === id
            return html`
              <button
                key=${id}
                type="button"
                class=${`ap-more-item ap-touch-target${active ? ' is-active' : ''}${locked ? ' is-locked' : ''}`}
                data-rbac-locked=${locked ? 'true' : undefined}
                onClick=${() => {
                  mobileMoreOpen.value = false
                  navigate(def.defaultPath)
                }}
              >
                <${ShellIcon} name=${id as ShellIconName} size=${16} />
                <span>${def.label}</span>
                ${locked && html`<${ShellIcon} name="lock" size=${12} />`}
              </button>
            `
          })}
        </div>

        <div class="ap-more-tools">
          <button
            type="button"
            class="ap-more-item ap-touch-target"
            onClick=${() => {
              mobileMoreOpen.value = false
              toggleQueueContextOverlay()
            }}
          >
            <${ShellIcon} name="layers" size=${16} />
            <span>Queue & Context</span>
          </button>
          <button
            type="button"
            class="ap-more-item ap-touch-target"
            onClick=${() => {
              mobileMoreOpen.value = false
              toggleIncidentsOverlay()
            }}
          >
            <${ShellIcon} name="bell" size=${16} />
            <span>Incidents ${unreadInc > 0 ? `(${unreadInc})` : ''}</span>
          </button>
          <button
            type="button"
            class="ap-more-item ap-touch-target"
            onClick=${() => {
              mobileMoreOpen.value = false
              openCommandPalette()
            }}
          >
            <${ShellIcon} name="search" size=${16} />
            <span>Command Palette</span>
          </button>
        </div>
      </div>
    `}

    <nav class="ap-mobile-bar" aria-label="모바일 탐색" data-testid="mobile-nav-bar">
      ${MOBILE_PRIMARY_TABS.map((id) => {
        const def = WORKSPACE_NAV_BY_ID[id]
        const active = route.workspace === id
        const badge = id === 'work' ? workBadge : null
        return html`
          <a
            key=${id}
            href=${`#${def.defaultPath}`}
            class=${`ap-mobile-tab ap-touch-target${active ? ' is-active' : ''}`}
            aria-current=${active ? 'page' : undefined}
            aria-label=${badge !== null ? `${def.label} (${workBadgeLabel})` : undefined}
            data-mobile-nav-id=${id}
            onClick=${(event: MouseEvent) => {
              if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
              event.preventDefault()
              mobileMoreOpen.value = false
              navigate(def.defaultPath)
            }}
          >
            <${ShellIcon} name=${id as ShellIconName} size=${18} />
            <span>${def.shortLabel}</span>
            ${badge !== null && html`
              <span class="ap-mobile-badge tnum" aria-hidden="true" title=${workBadgeLabel}>${badge}</span>
            `}
          </a>
        `
      })}
      <button
        type="button"
        class=${`ap-mobile-tab ap-touch-target${moreOpen || inMore ? ' is-active' : ''}`}
        aria-expanded=${moreOpen ? 'true' : 'false'}
        aria-label="더 보기"
        data-testid="mobile-more-trigger"
        onClick=${() => { mobileMoreOpen.value = !moreOpen }}
      >
        <${ShellIcon} name="more" size=${18} />
        <span>More</span>
        ${unreadInc > 0 && html`<span class="ap-mobile-badge tnum">${unreadInc}</span>`}
      </button>
    </nav>
  `
}
