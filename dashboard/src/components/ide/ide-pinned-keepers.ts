import { html } from 'htm/preact'
import { KeeperBadge } from '../keeper-badge'
import { useSignalValue } from './use-signal-value'
import { pinnedKeepers, promotePinAt, unpinKeeper } from './multi-keeper-pin-store'

/**
 * The keepers the operator pinned from the editor's ownership gutter, head
 * first. Pins were kept (and reordered by Mod+Shift+1..4) with nothing on
 * screen, so the shortcuts changed state nobody could see. A pin opens that
 * keeper as the IDE's target — the chat and the terminal follow the route
 * keeper — and × drops it.
 */
export function IdePinnedKeepers({
  onOpenKeeper,
}: {
  readonly onOpenKeeper: (keeperName: string) => void
}) {
  const pins = useSignalValue(pinnedKeepers)
  if (pins.entries.length === 0) return null

  return html`
    <div
      class="ide-presence ide-pinned-keepers v2-ide-panel"
      role="group"
      aria-label="Pinned keepers"
      data-testid="ide-pinned-keepers"
    >
      <span class="lbl">Pinned</span>
      <ul>
        ${pins.entries.map((entry, index) => {
          const where = entry.line === null ? '' : ` · L${entry.line}`
          const shortcut = index < pins.cap ? `Mod+Shift+${index + 1}` : undefined
          return html`
            <li key=${entry.keeperName}>
              <button
                type="button"
                class="v2-ide-action"
                data-testid="ide-pinned-keeper"
                aria-current=${index === 0 ? 'true' : undefined}
                aria-keyshortcuts=${shortcut}
                title=${`Open ${entry.keeperName}${where}`}
                onClick=${() => {
                  promotePinAt(index + 1)
                  onOpenKeeper(entry.keeperName)
                }}
              >
                <${KeeperBadge} id=${entry.keeperName} variant="sigil" size="sm" />
                <span>${entry.keeperName}${where}</span>
              </button>
              <button
                type="button"
                class="v2-ide-action"
                data-testid="ide-unpin-keeper"
                aria-label=${`Unpin ${entry.keeperName}`}
                title=${`Unpin ${entry.keeperName}`}
                onClick=${() => unpinKeeper(entry.keeperName)}
              >×</button>
            </li>
          `
        })}
      </ul>
    </div>
  `
}
