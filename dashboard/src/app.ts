import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { lazy, Suspense } from 'preact/compat'
import { isImeComposing } from './lib/keyboard'
import { route, initRouter } from './router'
import { requestNamespaceTruthNow, disposeNamespaceTruthScheduler } from './namespace-truth-store'
import { cancelPendingServerPushRefreshes, registerGateRefresh, setupServerPushReaction } from './sse-store'
import { initNotificationDelivery } from './notifications'
import { refreshShell, setupShellObservation } from './store'
import { connectDashboardObserver, disconnectDashboardObserver } from './dashboard-observer'
import {
  ensureDevToken,
  installRejectedCredentialRecovery,
} from './api/dev-token'
import { DashboardMain, DashboardHealthStrip, isKeeperDetailDashboardRoute } from './components/dashboard-shell'
import { RemoteWarningBanner } from './components/auth-status'
import { BundleStaleBanner, WorktreeServerBanner } from './components/bundle-stale-banner'
import { SkipLink } from './components/skip-link'
import { selectedAgentName } from './components/agent-detail-selection'
import { selectedTask } from './components/goals/task-detail-selection'
import { ToastContainer } from './components/common/toast'
import { ConfirmDialogOverlay } from './components/common/confirm-dialog'
import { commandPaletteRequested, requestCommandPaletteOpen } from './components/common/command-palette-state'
import { BundleStalenessBanner, installBundleStalenessWatch } from './components/bundle-staleness-banner'
import { startErrorCleanup, stopErrorCleanup } from './components/common/error-notification-state'
import { isPrimaryDashboardSurface } from './config/navigation'
import { gateData } from './components/gate-signals'
import type { TabId } from './types'
import { useKeyboardShortcutHost } from '../design-system/headless-preact/use-keyboard-shortcut'
import { matchesShortcutChord } from '../design-system/headless-core/keyboard-shortcuts'
import { globalShortcutManager } from './lib/global-shortcut-manager'
import { useIsMobile } from './hooks/use-is-mobile'
import { keeperMobilePane } from './components/keeper-detail-state'
import { TopBarV2 } from './components/v2/top-bar-v2'
import { NavRailV2 } from './components/v2/nav-rail-v2'

export function shouldSuppressFloatingChrome({
  currentTab,
  keeperDetailMode,
}: {
  currentTab: TabId
  keeperDetailMode: boolean
}): boolean {
  return keeperDetailMode || isPrimaryDashboardSurface(currentTab)
}

export function shouldShowDashboardHealthStrip(currentTab: TabId): boolean {
  return !isPrimaryDashboardSurface(currentTab)
}

const LazyAgentDetailOverlay = lazy(async () => ({
  default: (await import('./components/agent-detail')).AgentDetailOverlay,
}))
const LazyTaskDetailOverlay = lazy(async () => ({
  default: (await import('./components/goals/task-detail-overlay')).TaskDetailOverlay,
}))
const LazyCommandPalette = lazy(async () => ({
  default: (await import('./components/common/command-palette')).CommandPalette,
}))

export function shouldBootstrapCommandPaletteShortcut(
  event: Pick<KeyboardEvent, 'altKey' | 'ctrlKey' | 'key' | 'metaKey'>
    & Partial<Pick<KeyboardEvent, 'shiftKey' | 'defaultPrevented' | 'isComposing' | 'keyCode'>>,
  mounted: boolean,
): boolean {
  return !mounted
    && !event.defaultPrevented
    && !isImeComposing(event)
    && matchesShortcutChord({ key: 'k', modifiers: ['Mod'] }, event)
}

function refreshCurrentRoute(options?: { recordVisit?: boolean }): void {
  const routeState = route.value
  void import('./tab-refresh')
    .then(({ refreshForRoute }) => {
      refreshForRoute(routeState, options)
    })
    .catch(err => {
      console.warn('[app] route refresh unavailable', err instanceof Error ? err.message : err)
    })
}

export function App() {
  useKeyboardShortcutHost(globalShortcutManager)

  useEffect(() => {
    let cancelled = false
    const shellBoot = new AbortController()
    const stopShellObservation = setupShellObservation()

    initRouter()
    const uninstallCredentialRecovery = installRejectedCredentialRecovery()

    const ensureLoopbackAuth = () => ensureDevToken()
      .catch(err => {
        console.warn('[app] dashboard dev-token bootstrap failed', err instanceof Error ? err.message : err)
      })

    void ensureLoopbackAuth()
      .finally(() => {
        if (cancelled) return
        void refreshShell({ light: true, signal: shellBoot.signal })
        requestNamespaceTruthNow()
        connectDashboardObserver()
      })

    const refreshGateLazy = (opts?: { force?: boolean }) => {
      void import('./components/gate-refresh')
        .then(({ refreshGate }) => refreshGate(opts))
        .catch(err => {
          console.warn('[app] Gate refresh unavailable', err instanceof Error ? err.message : err)
        })
    }
    registerGateRefresh(refreshGateLazy)
    refreshGateLazy()

    const unsubscribeServerPush = setupServerPushReaction()
    const unsubNotify = initNotificationDelivery()
    startErrorCleanup()
    const uninstallStalenessWatch = installBundleStalenessWatch()

    return () => {
      cancelled = true
      shellBoot.abort()
      stopShellObservation()
      disconnectDashboardObserver()
      unsubscribeServerPush()
      unsubNotify()
      stopErrorCleanup()
      disposeNamespaceTruthScheduler()
      uninstallStalenessWatch()
      uninstallCredentialRecovery()
    }
  }, [])

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!shouldBootstrapCommandPaletteShortcut(event, commandPaletteRequested.value)) return
      event.preventDefault()
      requestCommandPaletteOpen()
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [])

  useEffect(() => {
    cancelPendingServerPushRefreshes()
    refreshCurrentRoute({ recordVisit: true })
  }, [route.value.tab, route.value.params.section, route.value.params.view, route.value.params.q])

  const isMobile = useIsMobile()
  const currentTab = route.value.tab
  const isScheduleSurface = currentTab === 'schedule'
  const keeperDetailMode = isKeeperDetailDashboardRoute(route.value)
  const mobileKeeperPane = isMobile && keeperDetailMode ? keeperMobilePane.value : null
  const mobileKeeperReadingMode = mobileKeeperPane === 'chat'

  const approvalsBadge =
    gateData.value?.approval_queue_state?.state === 'ready'
      ? { state: 'ready' as const, count: gateData.value.approval_queue?.length ?? 0 }
      : gateData.value?.approval_queue_state
        ? gateData.value.approval_queue_state
        : undefined

  const cols = isMobile ? 'minmax(0,1fr)' : '58px minmax(0,1fr)'

  return html`
    <div
      class="v2-app"
      data-surface=${currentTab}
      data-mobile=${isMobile ? '1' : null}
      data-keeper-detail-mode=${keeperDetailMode ? 'true' : 'false'}
      data-reading=${mobileKeeperReadingMode ? 'true' : 'false'}
    >
      <${SkipLink} />
      <${TopBarV2} />
      <${RemoteWarningBanner} />
      <${BundleStaleBanner} />
      <${WorktreeServerBanner} />
      <${DashboardHealthStrip} hidden=${!shouldShowDashboardHealthStrip(currentTab)} />

      <div class="v2-stage">
        <div class="v2-body" style=${{ gridTemplateColumns: cols }}>
          <${NavRailV2} badges=${{ approvals: approvalsBadge }} mobile=${isMobile} />
          <main
            id="main-content"
            tabindex=${-1}
            class="v2-surface-host"
            style=${{ minWidth: 0, minHeight: 0, overflowY: isScheduleSurface ? 'hidden' : 'auto' }}
          >
            <div class=${isScheduleSurface ? 'h-full overflow-hidden p-0' : keeperDetailMode ? 'h-full p-0' : 'dashboard-main-scroll h-full p-4 max-[900px]:pb-16'}>
              <div class="v2-surface" key=${currentTab}>
                <${DashboardMain} />
              </div>
            </div>
          </main>
        </div>
      </div>

      ${selectedAgentName.value
        ? html`<${Suspense} fallback=${null}><${LazyAgentDetailOverlay} /><//>`
        : null}
      ${selectedTask.value
        ? html`<${Suspense} fallback=${null}><${LazyTaskDetailOverlay} /><//>`
        : null}
      <${ToastContainer} />
      <${ConfirmDialogOverlay} />
      <${BundleStalenessBanner} />
      ${commandPaletteRequested.value
        ? html`
          <${Suspense} fallback=${null}>
            <${LazyCommandPalette} openOnMount=${true} />
          <//>
        `
        : null}
    </div>
  `
}
