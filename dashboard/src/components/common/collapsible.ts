// CollapsibleSection — consistent expandable section
// Replaces 5+ inline `<details class="rounded-[var(--r-1)] border border-[var(--color-border-default)] overflow-hidden">` patterns

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useEffect, useState } from 'preact/hooks'

interface CollapsibleSectionProps {
  title: ComponentChildren
  open?: boolean
  id?: string
  class?: string
  /** Summary extra content (badges, counts) */
  badge?: ComponentChildren
  /** Dot color class for the status indicator in the summary. */
  dotClass?: string
  /** Callback fired when the open state changes via user interaction. */
  onToggle?: (open: boolean) => void
  /** Avoid mounting expensive closed panels until the operator expands them. */
  mountWhenOpen?: boolean
  children: ComponentChildren
}

export function CollapsibleSection({
  title,
  open,
  id,
  class: cx,
  badge,
  dotClass,
  onToggle,
  mountWhenOpen = false,
  children,
}: CollapsibleSectionProps) {
  const [hasOpened, setHasOpened] = useState(Boolean(open))
  const shouldRenderChildren = !mountWhenOpen || hasOpened

  useEffect(() => {
    if (open) setHasOpened(true)
  }, [open])

  return html`
    <details
      open=${open}
      id=${id}
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] overflow-hidden ${cx ?? ''}"
      onToggle=${(event: Event) => {
        const isOpen = (event.currentTarget as HTMLDetailsElement).open
        if (isOpen) setHasOpened(true)
        onToggle?.(isOpen)
      }}
    >
      <summary class="flex items-center gap-2 px-4 py-3 cursor-pointer text-sm font-medium text-[var(--color-fg-secondary)] select-none hover:bg-[var(--color-bg-surface)] transition-colors list-none">
        ${dotClass != null ? html`<span class="w-1.5 h-1.5 rounded-full ${dotClass}" aria-hidden="true"></span>` : null}
        ${title}
        ${badge ?? null}
      </summary>
      <div class="p-4 pt-0">
        ${shouldRenderChildren ? children : null}
      </div>
    </details>
  `
}
