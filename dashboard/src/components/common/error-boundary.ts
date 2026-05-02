import { html } from 'htm/preact'
import { Component, type ComponentChildren } from 'preact'
import { AlertOctagon, AlertTriangle, RefreshCcw, RotateCw } from 'lucide-preact'

interface ErrorBoundaryInfo {
  componentStack?: string
}

// Phase 2 spec (`design-system/preview/cb-group-g.jsx:G3`) defines two
// inline error-banner tones:
//   - 'recoverable' (warn) + retry — soft amber, retry resets boundary
//   - 'fatal' (err) + retry + reload — soft red, reload reloads the window
// Production has historically rendered only the fatal tone with a single
// retry. Adding `severity` keeps the existing default while letting callers
// opt into the gentler recoverable framing, and the fatal default now also
// carries an explicit reload button per spec.
export type ErrorBoundarySeverity = 'recoverable' | 'fatal'

interface Props {
  label?: string
  severity?: ErrorBoundarySeverity
  fallback?: (error: Error, reset: () => void) => ComponentChildren
  onError?: (error: Error, info: ErrorBoundaryInfo) => void
  children: ComponentChildren
}

interface State {
  error: Error | null
}

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  private reset = (): void => {
    this.setState({ error: null })
  }

  private reload = (): void => {
    if (typeof window !== 'undefined') {
      window.location.reload()
    }
  }

  componentDidCatch(error: Error, info: ErrorBoundaryInfo) {
    console.error(`[ErrorBoundary:${this.props.label ?? 'unknown'}]`, error)
    this.props.onError?.(error, info)
  }

  render() {
    if (this.state.error) {
      if (this.props.fallback) {
        return this.props.fallback(this.state.error, this.reset)
      }

      const severity: ErrorBoundarySeverity = this.props.severity ?? 'fatal'
      if (severity === 'recoverable') {
        return html`
          <div
            class="error-card my-3 flex items-start gap-4 rounded-[var(--r-1)] border border-[var(--color-status-warn)]/30 bg-[var(--color-status-warn)]/10 p-5 shadow-sm"
            style="border-left: 3px solid var(--color-status-warn);"
            role="alert"
          >
            <div class="mt-0.5 shrink-0 text-[var(--color-status-warn)]">
              <${AlertTriangle} size=${24} />
            </div>
            <div class="min-w-0 flex-1">
              <h3 class="mb-1 text-2xs font-semibold uppercase tracking-1 text-[var(--color-status-warn)]">
                recoverable · ${this.props.label ?? '컴포넌트'}
              </h3>
              <pre class="overflow-x-auto whitespace-pre-wrap rounded bg-[var(--black-20)] p-2 text-sm text-[var(--color-fg-primary)] opacity-80">${this.state.error.message}</pre>
              <button
                type="button"
                class="mt-3 inline-flex cursor-pointer items-center justify-center gap-1.5 rounded-[var(--r-1)] border border-[var(--color-status-warn)]/40 bg-[var(--color-status-warn)]/10 px-3 py-1.5 text-sm text-[var(--color-status-warn)] transition-colors hover:bg-[var(--color-status-warn)]/20 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-status-warn)]"
                onClick=${this.reset}
              >
                <${RefreshCcw} size=${14} />
                다시 시도
              </button>
            </div>
          </div>
        `
      }

      // severity === 'fatal' — original tone + an explicit reload button
      return html`
        <div
          class="error-card my-3 flex items-start gap-4 rounded-[var(--r-1)] border border-[var(--err-border)] bg-[var(--color-bg-elevated)] p-5 shadow-sm"
          style="border-left: 3px solid var(--color-status-err);"
          role="alert"
        >
          <div class="mt-0.5 shrink-0 text-[var(--color-status-err)]">
            <${AlertOctagon} size=${24} />
          </div>
          <div class="min-w-0 flex-1">
            <h3 class="mb-1 text-base font-semibold tracking-tight text-[var(--color-status-err)]">${this.props.label ?? 'Component'} 렌더링 오류</h3>
            <pre class="overflow-x-auto whitespace-pre-wrap rounded bg-[var(--black-20)] p-2 text-sm text-[var(--color-fg-primary)] opacity-80">${this.state.error.message}</pre>
            <div class="mt-3 flex flex-wrap gap-2">
              <button
                type="button"
                class="inline-flex cursor-pointer items-center justify-center gap-1.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--white-5)] px-3 py-1.5 text-sm text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--white-10)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-status-err)]"
                onClick=${this.reset}
              >
                <${RefreshCcw} size=${14} />
                다시 시도
              </button>
              <button
                type="button"
                class="inline-flex cursor-pointer items-center justify-center gap-1.5 rounded-[var(--r-1)] border border-[var(--color-status-err)]/50 bg-[var(--color-status-err)]/15 px-3 py-1.5 text-sm font-medium text-[var(--color-status-err)] transition-colors hover:bg-[var(--color-status-err)]/25 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-status-err)]"
                onClick=${this.reload}
              >
                <${RotateCw} size=${14} />
                세션 리로드
              </button>
            </div>
          </div>
        </div>
      `
    }
    return this.props.children
  }
}
