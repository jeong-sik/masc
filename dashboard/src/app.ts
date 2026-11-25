/**
 * Proposal A+ Ultra-Lean Application Shell (`src/app.ts`).
 *
 * - Strict capability-gated boot: `bootstrapAuthSession()` -> `startObserverStream()`
 *   (zero speculative 401/403/404 requests; zero hidden `DashboardHealthStrip`; zero `CopilotDock` FAB).
 * - Declarative RBAC guard via `evaluateRouteAccess()` (blocks non-Admin from mounting `/infra/*` or `/settings`).
 * - Lazy workspace loading via `getWorkspaceComponent()` + lazy `CommandPalette`.
 * - Single Read-Only `QuickPeekDrawer` host (`inspect | queue_context | incidents`).
 */

import { html } from 'htm/preact'
import { Component, type ComponentChildren, type VNode } from 'preact'
import { lazy, Suspense } from 'preact/compat'
import { useEffect } from 'preact/hooks'
import {
  authSession,
  bootstrapAuthSession,
  installAuthLifecycleGuards,
  isAuthenticated,
} from './core/auth'
import { startObserverStream, stopObserverStream } from './core/observer'
import { releaseAllViewStreams } from './core/view-stream-slot'
import { QuickPeekDrawer } from './components/primitives/quick-peek-drawer'
import {
  TRUNK_NAV,
  currentRoute,
  evaluateRouteAccess,
  initAPlusRouter,
  navigate,
} from './routes/router'
import { getWorkspaceComponent, WorkspaceLoadError } from './workspaces/registry'
import {
  FastApprovalStrip,
  IncidentsOverlayBody,
  MobileNav,
  NavRail,
  QueueContextOverlayBody,
  ShellIcon,
  TopBar,
  activeOverlay,
  closeActiveOverlay,
  commandPaletteMounted,
  commandPaletteOpen,
  dismissShellToast,
  installShellObservers,
  installViewportListener,
  isMobileViewport,
  openCommandPalette,
  openInspectDrawer,
  probeBuildConnectionInfo,
  recordIncident,
  refreshPendingHitl,
  shellToasts,
  toggleIncidentsOverlay,
  toggleQueueContextOverlay,
  toggleRail,
} from './shell/index'

const LazyCommandPalette = lazy(async () => ({
  default: (await import('./shell/command-palette')).CommandPalette,
}))

function isImeComposing(
  event: Partial<Pick<KeyboardEvent, 'isComposing' | 'keyCode'>>,
): boolean {
  return event.isComposing === true || event.keyCode === 229
}

function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  const tag = target.tagName
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || target.isContentEditable
}

/**
 * Pure predicate guarding the first `⌘K` / `Ctrl+K` Command Palette bootstrap shortcut
 * against IME composition, extra modifiers, and already-handled events.
 */
export function shouldBootstrapCommandPaletteShortcut(
  event: Pick<KeyboardEvent, 'altKey' | 'ctrlKey' | 'key' | 'metaKey'>
    & Partial<Pick<KeyboardEvent, 'shiftKey' | 'defaultPrevented' | 'isComposing' | 'keyCode'>>,
  mounted: boolean,
): boolean {
  if (mounted || event.defaultPrevented || isImeComposing(event)) return false
  if (event.altKey || event.shiftKey) return false
  if (event.key.toLowerCase() !== 'k') return false
  return (event.metaKey && !event.ctrlKey) || (event.ctrlKey && !event.metaKey)
}

interface BoundaryProps {
  readonly resetKey: string
  readonly children: ComponentChildren
}

interface BoundaryState {
  readonly error: Error | null
}

class WorkspaceErrorBoundary extends Component<BoundaryProps, BoundaryState> {
  override state: BoundaryState = { error: null }

  static getDerivedStateFromError(error: Error): BoundaryState {
    return { error }
  }

  override componentDidUpdate(prevProps: BoundaryProps): void {
    if (prevProps.resetKey !== this.props.resetKey && this.state.error !== null) {
      this.setState({ error: null })
    }
  }

  override componentDidCatch(error: Error): void {
    recordIncident({
      severity: 'error',
      source: 'workspace',
      summary: `Workspace render error (${this.props.resetKey})`,
      detail: error.message,
    })
  }

  override render() {
    if (this.state.error) {
      const loadFailed = this.state.error instanceof WorkspaceLoadError
        || /dynamically imported module|Loading chunk|Failed to fetch/i.test(this.state.error.message)
      return html`
        <section class="ap-gate" role="alert">
          <div class="ap-card">
            <h1 class="ap-card-title">
              ${loadFailed ? '대시보드가 새 버전으로 업데이트되었습니다' : '화면을 표시하는 중 오류가 발생했습니다'}
            </h1>
            <p class="ap-muted mono">
              ${loadFailed
                ? '이전 번들 청크가 교체되어 새로고침이 필요합니다. 아래 버튼을 눌러 최신 화면을 불러오세요.'
                : this.state.error.message}
            </p>
            <div class="ap-placeholder-actions">
              <button type="button" class="btn-primary" onClick=${() => {
                if (loadFailed) window.location.reload()
                else this.setState({ error: null })
              }}>
                ${loadFailed ? '새로고침' : '다시 시도'}
              </button>
              <button type="button" class="btn-ghost" onClick=${() => navigate('/pulse')}>
                Pulse로 이동
              </button>
            </div>
          </div>
        </section>
      `
    }
    return this.props.children
  }
}

function SkipLink(): VNode {
  return html`
    <a
      href="#main-content"
      class="sr-only"
      onClick=${(event: MouseEvent) => {
        const main = document.getElementById('main-content')
        if (!main) return
        event.preventDefault()
        main.focus()
      }}
    >
      Skip to main content
    </a>
  `
}

function ShellToastHost(): VNode | null {
  const items = shellToasts.value
  if (items.length === 0) return null
  return html`
    <div class="ap-toast-host" aria-live="polite" aria-atomic="true">
      ${items.map((toast) => html`
        <div key=${toast.id} role=${toast.tone === 'error' ? 'alert' : 'status'} class=${`ap-toast ap-toast--${toast.tone}`}>
          <span>${toast.message}</span>
          <button
            type="button"
            class="ap-toast-close"
            aria-label="닫기"
            onClick=${() => dismissShellToast(toast.id)}
          >
            <${ShellIcon} name="x" size=${13} />
          </button>
        </div>
      `)}
    </div>
  `
}

function WorkspaceHost(): VNode {
  const route = currentRoute.value
  const session = authSession.value
  const decision = evaluateRouteAccess(route.access, session)

  if (!decision.allowed) {
    if (decision.reason === 'probing') {
      return html`
        <section class="ap-gate" role="status" data-testid="route-gate-probing">
          <div class="ap-card">
            <p class="ap-muted">세션 및 권한을 확인하는 중…</p>
          </div>
        </section>
      `
    }
    if (decision.reason === 'admin_only') {
      return html`
        <section class="ap-gate" role="status" data-testid="route-gate-admin-only">
          <div class="ap-card">
            <span class="ap-eyebrow">RBAC · ADMIN ONLY</span>
            <h1 class="ap-card-title">관리자 전용 경로입니다</h1>
            <p class="ap-muted">
              현재 계정은 <code class="mono">${route.path}</code> 접근 권한이 없습니다.
              권한 없는 API 요청은 전송하지 않습니다.
            </p>
            <div class="ap-placeholder-actions">
              <button type="button" class="btn-primary" onClick=${() => navigate('/pulse')}>
                1 Pulse로 이동
              </button>
              <button type="button" class="btn-ghost" onClick=${() => navigate('/account')}>
                Account 확인
              </button>
            </div>
          </div>
        </section>
      `
    }
    if (decision.reason === 'account_changed') {
      return html`
        <section class="ap-gate" role="alert" data-testid="route-gate-account-changed">
          <div class="ap-card ap-inline-panel--err">
            <h1 class="ap-card-title">다른 탭에서 계정이 변경되었습니다</h1>
            <p class="ap-muted">세션을 다시 불러온 뒤 계속 진행하세요.</p>
            <div class="ap-placeholder-actions">
              <button
                type="button"
                class="btn-primary"
                onClick=${() => { void bootstrapAuthSession().then(() => startObserverStream()) }}
              >
                세션 다시 불러오기
              </button>
            </div>
          </div>
        </section>
      `
    }
    if (decision.reason === 'unavailable') {
      return html`
        <section class="ap-gate" role="alert" data-testid="route-gate-unavailable">
          <div class="ap-card">
            <h1 class="ap-card-title">MASC 서버에 연결할 수 없습니다</h1>
            <p class="ap-muted">${session.kind === 'unavailable' ? session.reason : '서버 응답 없음'}</p>
            <div class="ap-placeholder-actions">
              <button
                type="button"
                class="btn-primary"
                onClick=${() => { void bootstrapAuthSession().then(() => startObserverStream()) }}
              >
                다시 연결
              </button>
              <button type="button" class="btn-ghost" onClick=${() => navigate('/account')}>
                Account / Targets
              </button>
            </div>
          </div>
        </section>
      `
    }
    return html`
      <section class="ap-gate" role="status" data-testid="route-gate-auth-required">
        <div class="ap-card">
          <span class="ap-eyebrow">AUTHENTICATION REQUIRED</span>
          <h1 class="ap-card-title">로그인이 필요합니다</h1>
          <p class="ap-muted">
            인증되지 않은 상태에서는 보호된 데이터를 요청하지 않습니다. Account 화면에서 로그인하거나 토큰을 설정하세요.
          </p>
          <div class="ap-placeholder-actions">
            <button type="button" class="btn-primary" onClick=${() => navigate('/account')}>
              Account 로그인으로 이동
            </button>
          </div>
        </div>
      </section>
    `
  }

  const ActiveWorkspace = getWorkspaceComponent(route.workspace)
  return html`
    <${WorkspaceErrorBoundary} resetKey=${route.path}>
      <${Suspense} fallback=${html`<section class="ap-gate" role="status"><div class="ap-card"><p class="ap-muted">워크스페이스 불러오는 중…</p></div></section>`}>
        <${ActiveWorkspace}
          subroute=${route.subroute}
          entityId=${route.entityId}
          entityTab=${route.entityTab}
          onNavigate=${(path: string) => { navigate(path) }}
          onInspect=${openInspectDrawer}
        />
      <//>
    <//>
  `
}

function QuickPeekHost(): VNode | null {
  const overlay = activeOverlay.value
  if (overlay === null) return null

  if (overlay.kind === 'queue_context') {
    return html`
      <${QuickPeekDrawer}
        open=${true}
        title="Queue & Context"
        subtitle="⌘T Read-Only Quick-Peek"
        onClose=${closeActiveOverlay}
      >
        <${QueueContextOverlayBody} />
      <//>
    `
  }

  if (overlay.kind === 'incidents') {
    return html`
      <${QuickPeekDrawer}
        open=${true}
        title="Historical Incidents (Ch3)"
        subtitle="[I] Read-Only · Isolated from Live SSOT"
        onClose=${closeActiveOverlay}
      >
        <${IncidentsOverlayBody} />
      <//>
    `
  }

  const { payload } = overlay
  return html`
    <${QuickPeekDrawer}
      open=${true}
      title=${payload.title}
      subtitle=${payload.subtitle}
      onClose=${closeActiveOverlay}
    >
      ${payload.render
        ? payload.render()
        : html`<pre class="ap-inspect-json mono">${JSON.stringify(payload.data ?? {}, null, 2)}</pre>`}
    <//>
  `
}

export function App(): VNode {
  const mobile = isMobileViewport.value
  const route = currentRoute.value
  const paletteMounted = commandPaletteMounted.value

  // Capability-gated bootstrap: `/health` -> `AuthSession` -> `startObserverStream()`
  useEffect(() => {
    let disposed = false
    const stopViewport = installViewportListener()
    const stopRouter = initAPlusRouter()
    const stopAuthGuards = installAuthLifecycleGuards()
    const stopShellObservers = installShellObservers()

    void bootstrapAuthSession().then((session) => {
      if (disposed) return
      if (session.kind === 'single_user_local' || session.kind === 'multi_account_signed_in') {
        void startObserverStream()
        void probeBuildConnectionInfo()
        if (session.kind === 'single_user_local') {
          void refreshPendingHitl()
        }
      }
    })

    return () => {
      disposed = true
      stopViewport()
      stopRouter()
      stopAuthGuards()
      stopShellObservers()
      stopObserverStream()
      releaseAllViewStreams()
    }
  }, [])

  // Global A+ Shell Keyboard Shortcuts
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || isImeComposing(event)) return

      const mod = (event.metaKey && !event.ctrlKey) || (event.ctrlKey && !event.metaKey)
      const lower = event.key.toLowerCase()

      if (mod && !event.altKey && !event.shiftKey && lower === 'k') {
        event.preventDefault()
        if (commandPaletteOpen.peek()) {
          commandPaletteOpen.value = false
        } else {
          openCommandPalette()
        }
        return
      }

      if (mod && !event.altKey && !event.shiftKey && lower === 't') {
        event.preventDefault()
        toggleQueueContextOverlay()
        return
      }

      if (mod || event.altKey || event.ctrlKey || event.metaKey) return
      if (isEditableTarget(event.target)) return
      if (commandPaletteOpen.peek()) return

      if (lower === 'b') {
        event.preventDefault()
        toggleRail()
        return
      }
      if (lower === 'i') {
        event.preventDefault()
        toggleIncidentsOverlay()
        return
      }
      if (event.key === ',') {
        event.preventDefault()
        navigate('/settings')
        return
      }
      if (event.key >= '1' && event.key <= '6') {
        const trunk = TRUNK_NAV[Number(event.key) - 1]
        if (trunk) {
          event.preventDefault()
          navigate(trunk.defaultPath)
        }
      }
    }

    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [])

  return html`
    <div
      class="ap-shell"
      data-workspace=${route.workspace}
      data-mobile=${mobile ? 'true' : 'false'}
      data-authenticated=${isAuthenticated.value ? 'true' : 'false'}
    >
      <${SkipLink} />
      <${TopBar} />
      <${FastApprovalStrip} />

      <div class="ap-stage">
        ${!mobile && html`<${NavRail} />`}
        <main id="main-content" tabindex=${-1} class="ap-main">
          <${WorkspaceHost} />
        </main>
        <${QuickPeekHost} />
      </div>

      ${mobile && html`<${MobileNav} />`}
      <${ShellToastHost} />

      ${paletteMounted && html`
        <${Suspense} fallback=${null}>
          <${LazyCommandPalette} />
        <//>
      `}
    </div>
  `
}
