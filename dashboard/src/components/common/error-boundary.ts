import { html } from 'htm/preact'
import { Component, type ComponentChildren } from 'preact'
import { AlertOctagon, RefreshCcw } from 'lucide-preact'

interface ErrorBoundaryInfo {
  componentStack?: string
}

interface Props {
  label?: string
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

  componentDidCatch(error: Error, info: ErrorBoundaryInfo) {
    console.error(`[ErrorBoundary:${this.props.label ?? 'unknown'}]`, error)
    this.props.onError?.(error, info)
  }

  render() {
    if (this.state.error) {
      if (this.props.fallback) {
        return this.props.fallback(this.state.error, this.reset)
      }
      return html`
        <div class="error-card rounded my-3 border border-[var(--bad)]/30 bg-[rgba(10,22,40,0.92)] p-5 flex gap-4 items-start shadow-sm" role="alert">
          <div class="shrink-0 text-[var(--bad)] mt-0.5" aria-hidden="true">
            <${AlertOctagon} size=${24} />
          </div>
          <div class="flex-1 min-w-0">
            <h3 class="text-base font-semibold text-[var(--bad)] tracking-tight mb-1">${this.props.label ?? 'Component'} 렌더링 오류</h3>
            <pre class="text-sm whitespace-pre-wrap opacity-80 text-[var(--text-body)] overflow-x-auto bg-[var(--black-20)] p-2 rounded leading-[1.4]" tabindex="0">${this.state.error.message}</pre>
            <button type="button"
              class="mt-3 inline-flex items-center justify-center gap-1.5 px-3 py-1.5 cursor-pointer rounded border border-[var(--card-border)] bg-[var(--white-5)] text-[var(--text-strong)] text-sm hover:bg-[var(--white-10)] transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--bad)]"
              onClick=${this.reset}
            >
              <${RefreshCcw} size=${14} aria-hidden="true" />
              다시 시도
            </button>
          </div>
        </div>
      `
    }
    return this.props.children
  }
}
