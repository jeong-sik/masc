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
        <div class="error-card" style="margin: 12px 0;">
          <strong>${this.props.label ?? 'Component'} render error</strong>
          <pre style="font-size: 12px; white-space: pre-wrap; margin-top: 8px; opacity: 0.7;">${this.state.error.message}</pre>
          <button
            style="margin-top: 8px; padding: 4px 12px; cursor: pointer;"
            onClick=${() => this.setState({ error: null })}
          >Retry</button>
        </div>
      `
    }
    return this.props.children
  }
}
