import { html } from 'htm/preact'
import { openIdeContextRouteLink, type IdeContextRouteLink } from './ide-context-lens'

export function EditorContextRouteLink(link: IdeContextRouteLink) {
  return html`
    <button
      key=${link.id}
      type="button"
      class="ide-editor-context-route-link v2-ide-action"
      title=${link.evidence}
      aria-label=${`Open ${link.evidence}`}
      onClick=${() => openIdeContextRouteLink(link)}
    >
      ${link.label}
    </button>
  `
}

export function EditorContextRouteCount({
  count,
  label,
}: {
  readonly count: number
  readonly label: string
}) {
  return html`
    <span
      class="ide-editor-context-route-count"
      title=${`${count} linked ${label} routes`}
      aria-label=${`${count} linked ${label} routes`}
    >
      CTX ${count}
    </span>
  `
}
