// ConnectorBindingSummary — 1-line per binding "kpr-a → #general (in Acme)"
// list rendered between the readiness rail and the detail panel. Surfaces
// the actual channel names the operator wired up so they can confirm at a
// glance (instead of only seeing the count "2 bindings"), and exposes a
// 1-click 🔗 anchor that scroll-jumps into the keeper section's existing
// per-binding row for unbind/details.
//
// We don't replicate the keeper-section UI here — bindings beyond the
// first 6 collapse to "+N more" so a connector with 50 bound channels
// doesn't blow out the card. The full list lives in the keeper section.

import { html } from 'htm/preact'
import type { DiscordConfiguredBinding, ConnectorNames } from '../api/gate'
import { humanizeChannel } from './connector-status'

const COLLAPSE_AFTER = 6

export interface BindingSummaryProps {
  connectorId: string
  bindings: DiscordConfiguredBinding[]
  names: ConnectorNames | undefined
}

function describeBinding(b: DiscordConfiguredBinding, names: ConnectorNames | undefined): string {
  const human = humanizeChannel(names, b.channel_id)
  return human ? `#${human}` : b.channel_id
}

export function ConnectorBindingSummary({ connectorId, bindings, names }: BindingSummaryProps) {
  if (bindings.length === 0) return null
  const visible = bindings.slice(0, COLLAPSE_AFTER)
  const overflow = bindings.length - visible.length

  const onJump = () => {
    const el = document.getElementById(`keepers-${connectorId}`)
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }

  return html`
    <ul
      class="mt-2 space-y-1 rounded-md border border-[var(--card-border)] bg-[var(--white-2)] px-3 py-2 text-[11px]"
      data-binding-summary=${connectorId}
    >
      ${visible.map(b => html`
        <li class="flex min-w-0 items-center gap-2">
          <button
            type="button"
            class="shrink-0 cursor-pointer text-[var(--text-dim)] hover:text-[var(--text-body)]"
            title="keeper 섹션으로 이동"
            aria-label=${`Jump to keeper section for ${b.keeper_name}`}
            onClick=${onJump}
          >🔗</button>
          <span class="shrink-0 font-mono text-[var(--text-body)]">${b.keeper_name}</span>
          <span class="shrink-0 text-[var(--text-dim)]">→</span>
          <span class="min-w-0 truncate text-[var(--text-body)]" title=${b.channel_id}>${describeBinding(b, names)}</span>
        </li>
      `)}
      ${overflow > 0
        ? html`
            <li class="pt-1 text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]">
              <button
                type="button"
                class="cursor-pointer hover:text-[var(--text-body)]"
                onClick=${onJump}
                aria-label="show all bindings in keeper section"
              >+${overflow} more — keeper 섹션으로 이동</button>
            </li>
          `
        : null}
    </ul>
  `
}
