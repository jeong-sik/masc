import { html } from 'htm/preact'
import { Component, type ComponentChildren } from 'preact'

interface Props {
  label?: string
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

  componentDidCatch(error: Error) {
    console.error(`[ErrorBoundary:${this.props.label ?? 'unknown'}]`, error)
  }

  render() {
    if (this.state.error) {
      return html`
        <div class="error-card my-3 rounded-lg border border-[var(--bad)]/30 bg-[rgba(10,22,40,0.92)] p-4">
          <strong class="text-[var(--bad)]">${this.props.label ?? 'Component'} 렌더링 오류</strong>
          <pre class="text-xs whitespace-pre-wrap mt-2 opacity-70">${this.state.error.message}</pre>
          <button
            class="mt-2 px-3 py-1 cursor-pointer rounded border border-[var(--card-border)] bg-[var(--white-6)] text-[var(--text-body)] text-sm hover:bg-[var(--white-10)]"
            onClick=${() => this.setState({ error: null })}
          >다시 시도</button>
        </div>
      `
    }
    return this.props.children
  }
}
