import { html } from 'htm/preact'

interface SkipLinkProps {
  readonly targetId?: string
  readonly label?: string
}

export function SkipLink({
  targetId = 'main-content',
  label = 'Skip to main content',
}: SkipLinkProps) {
  return html`
    <a
      href=${`#${targetId}`}
      class="sr-only skip-link"
      onClick=${(event: MouseEvent) => {
        const target = document.getElementById(targetId)
        if (!target) return
        event.preventDefault()
        target.focus()
      }}
    >${label}</a>
  `
}
