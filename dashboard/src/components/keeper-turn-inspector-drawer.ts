import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { KeeperTurnInspector } from './keeper-turn-inspector'

/**
 * Right-side drawer hosting {@link KeeperTurnInspector}. Shared by the keeper
 * chat workspace (anchored to a chat entry's turn) and the board post detail
 * (anchored to a post's origin turn_ref, RFC-0233 §7). KeeperTurnInspector
 * self-fetches the keeper's turn records by `keeperName`, so a caller only
 * supplies the anchor (`initialTurnRef`/`initialTurnTimestamp`) and chrome.
 *
 * `testId` namespaces the drawer/close data-testids per surface so existing
 * surface tests keep their stable selectors (`${testId}-drawer`/`-close`).
 */
export function TurnInspectorDrawer({
  keeperName,
  subtitle,
  initialTurnRef,
  initialTurnTimestamp,
  open,
  onClose,
  testId,
}: {
  keeperName: string
  // Header secondary line; falls back to keeperName when null/undefined.
  subtitle?: string | null
  initialTurnRef?: string | null
  initialTurnTimestamp?: string | null
  open: boolean
  onClose: () => void
  testId: string
}): VNode | null {
  if (!open) return null

  return html`
    <div
      class="fixed inset-0 z-50 flex justify-end bg-black/40"
      role="dialog"
      aria-modal="true"
      aria-label="턴 검사"
      data-testid=${`${testId}-drawer`}
      onClick=${onClose}
    >
      <div
        class="h-full w-full max-w-2xl overflow-y-auto bg-[var(--color-bg-page)] shadow-2xl"
        onClick=${(e: Event) => e.stopPropagation()}
      >
        <div class="sticky top-0 z-10 flex items-center justify-between border-b border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-4 py-3 v2-monitoring-toolbar">
          <div>
            <h3 class="text-sm font-semibold text-[var(--color-fg-primary)]">턴 검사</h3>
            <p class="text-2xs text-[var(--color-fg-muted)]">${subtitle ?? keeperName}</p>
          </div>
          <button
            type="button"
            class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-1.5 text-2xs text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)]"
            onClick=${onClose}
            data-testid=${`${testId}-close`}
          >닫기</button>
        </div>
        <${KeeperTurnInspector}
          keeperName=${keeperName}
          initialTurnRef=${initialTurnRef ?? null}
          initialTurnTimestamp=${initialTurnTimestamp ?? null}
        />
      </div>
    </div>
  `
}
