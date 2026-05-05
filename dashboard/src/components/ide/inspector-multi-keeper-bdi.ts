import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  InspectorKeeperBDI,
  KeeperBdiSnapshot,
  normalizeKeeperBdiSnapshot,
} from './inspector-keeper-bdi'
import {
  pinKeeper,
  pinnedKeepers,
  PIN_CAP,
  PinnedKeeperEntry,
  unpinKeeper,
} from './multi-keeper-pin-store'

/**
 * RFC-0027 PR-β: multi-keeper BDI inspector with three layouts.
 *
 *  | entries.length | layout         | description                                |
 *  |----------------|----------------|--------------------------------------------|
 *  | 0              | single (legacy)| `InspectorKeeperBDI` falls back to active. |
 *  | 1              | single (legacy)| `InspectorKeeperBDI` reads head pin.       |
 *  | 2-3            | compact-fold   | full panel + reduced panels stacked.       |
 *  | 4              | focus-mode     | 1 focused panel + 3 promote-to-focus chips.|
 *
 * Backward-compat (RFC-0027 §10): for `entries.length <= 1` the legacy
 * single-pin component is rendered verbatim — there is no visual diff for
 * existing callers; PR-β only activates when 2+ keepers are pinned.
 *
 * Polling budget (RFC-0027 §6): always invokes `useKeeperBdiSnapshot` exactly
 * `PIN_CAP` (=4) times to satisfy Rules of Hooks (no loop-with-variable-count).
 * Empty `keeperName` short-circuits the effect, so unused slots issue zero
 * fetches. With 4 active pins at default `pollMs=5000`, the client emits
 * 0.8 fetch/sec which the server's 5s TTL cache absorbs.
 *
 * Display label resolution (RFC-0027 §3.1): the AgentPresence label fallback
 * is intentionally a *render-time* lookup against `keeper-presence-store`
 * rather than a stored field on `PinnedKeeperEntry`. This keeps the store
 * minimal and makes presence the single source of truth.
 */

const MULTI_BDI_CONTAINER_STYLE = {
  display: 'grid',
  gap: 'var(--sp-2)',
  padding: 'var(--sp-3)',
  borderBottom: '1px solid var(--color-border-divider)',
  background: 'var(--color-bg-surface)',
} as const

const CHIP_GROUP_STYLE = {
  display: 'flex',
  flexWrap: 'wrap',
  gap: 'var(--sp-1)',
} as const

const PANEL_STYLE_FOCUSED = {
  display: 'grid',
  gap: 'var(--sp-2)',
  padding: 'var(--sp-2)',
  border: '1px solid var(--color-accent-border)',
  borderRadius: '6px',
  background: 'var(--color-bg-elevated)',
} as const

const PANEL_STYLE_COMPACT = {
  display: 'grid',
  gap: '4px',
  padding: 'var(--sp-2)',
  border: '1px solid var(--color-border-divider)',
  borderRadius: '6px',
  background: 'var(--color-bg-surface)',
} as const

const CHIP_BUTTON_STYLE = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: '4px',
  padding: '2px 8px',
  border: '1px solid var(--color-border-divider)',
  borderRadius: '12px',
  background: 'var(--color-bg-surface)',
  color: 'var(--color-fg-secondary)',
  fontSize: 'var(--fs-11)',
  cursor: 'pointer',
} as const

const ROLLUP_STYLE = {
  display: 'flex',
  alignItems: 'baseline',
  gap: 'var(--sp-2)',
  padding: '4px 8px',
  borderRadius: '4px',
  background: 'var(--color-bg-elevated)',
  fontSize: 'var(--fs-11)',
  color: 'var(--color-fg-muted)',
} as const

interface KeeperBdiSlot {
  readonly snapshot: KeeperBdiSnapshot | null
  readonly error: string | null
}

const EMPTY_SLOT: KeeperBdiSlot = { snapshot: null, error: null }

function useKeeperBdiSnapshot(keeperName: string, pollMs: number): KeeperBdiSlot {
  const [snapshot, setSnapshot] = useState<KeeperBdiSnapshot | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const name = keeperName.trim()
    if (!name) {
      setSnapshot(null)
      setError(null)
      return
    }

    const controller = new AbortController()
    let timer: number | null = null

    const refresh = async () => {
      try {
        const res = await fetch(
          `/api/v1/keepers/${encodeURIComponent(name)}/bdi-snapshot`,
          { signal: controller.signal },
        )
        if (controller.signal.aborted) return
        if (!res.ok) {
          setError('snapshot unavailable')
          setSnapshot(null)
          return
        }
        const next = normalizeKeeperBdiSnapshot(await res.json())
        if (controller.signal.aborted) return
        setSnapshot(next)
        setError(next ? null : 'snapshot unavailable')
      } catch {
        if (!controller.signal.aborted) setError('snapshot unavailable')
      }
    }

    void refresh()
    timer = window.setInterval(refresh, Math.max(1000, pollMs))
    return () => {
      controller.abort()
      if (timer !== null) window.clearInterval(timer)
    }
  }, [keeperName, pollMs])

  return { snapshot, error }
}

function usePinnedKeepers(): ReadonlyArray<PinnedKeeperEntry> {
  const [snapshot, setSnapshot] = useState(pinnedKeepers.value)
  useEffect(() => pinnedKeepers.subscribe(value => setSnapshot(value)), [])
  return snapshot.entries
}

function rollupTokens(snapshots: ReadonlyArray<KeeperBdiSnapshot | null>): number | null {
  let sum = 0
  let any = false
  for (const snap of snapshots) {
    const total = snap?.recent_token_spend?.[0]?.total_tokens
    if (typeof total === 'number') {
      sum += total
      any = true
    }
  }
  return any ? sum : null
}

function formatTokenCount(value: number | null): string {
  return value === null ? '—' : `${value.toLocaleString()} tok`
}

interface RollupChipProps {
  readonly snapshots: ReadonlyArray<KeeperBdiSnapshot | null>
  readonly count: number
}

function RollupChip({ snapshots, count }: RollupChipProps) {
  const total = rollupTokens(snapshots)
  return html`
    <div role="status" aria-label="cross-keeper token rollup" style=${ROLLUP_STYLE}>
      <span style=${{ font: 'var(--type-eyebrow)' }}>Σ ${count}</span>
      <span style=${{ color: 'var(--color-fg-secondary)' }}>${formatTokenCount(total)}</span>
    </div>
  `
}

interface KeeperPanelProps {
  readonly entry: PinnedKeeperEntry
  readonly slot: KeeperBdiSlot
  readonly compact: boolean
  readonly focused: boolean
  readonly onUnpin: (keeperName: string) => void
}

function KeeperPanel({ entry, slot, compact, focused, onUnpin }: KeeperPanelProps) {
  const snapshot = slot.snapshot
  const error = slot.error
  const lastTool = snapshot?.last_tool_call ?? null

  return html`
    <article
      role="listitem"
      aria-current=${focused ? 'true' : 'false'}
      data-keeper=${entry.keeperName}
      data-compact=${compact ? 'true' : 'false'}
      style=${focused ? PANEL_STYLE_FOCUSED : PANEL_STYLE_COMPACT}
    >
      <header style=${{ display: 'flex', alignItems: 'baseline', gap: 'var(--sp-2)' }}>
        <span style=${{ color: 'var(--color-accent-fg)', fontSize: 'var(--fs-12)' }}>
          ${entry.keeperName}
        </span>
        ${entry.line !== null
          ? html`<span style=${{ color: 'var(--color-fg-muted)', fontSize: 'var(--fs-11)' }}>L${entry.line}</span>`
          : null}
        <button
          type="button"
          aria-label=${`unpin ${entry.keeperName}`}
          onClick=${() => onUnpin(entry.keeperName)}
          style=${{
            marginLeft: 'auto',
            border: 'none',
            background: 'transparent',
            color: 'var(--color-fg-muted)',
            cursor: 'pointer',
            fontSize: 'var(--fs-12)',
          }}
        >
          ×
        </button>
      </header>

      ${error
        ? html`<div role="status" style=${{ color: 'var(--color-status-warn)', fontSize: 'var(--fs-11)' }}>${error}</div>`
        : null}

      ${compact
        ? html`
            <div style=${{ display: 'grid', gap: '2px', fontSize: 'var(--fs-11)', color: 'var(--color-fg-secondary)' }}>
              <span><b>I:</b> ${snapshot?.intention ?? '—'}</span>
              ${lastTool?.tool ? html`<span style=${{ color: 'var(--color-fg-muted)' }}>last: ${lastTool.tool}</span>` : null}
            </div>
          `
        : html`
            <div style=${{ display: 'grid', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
              <div><span style=${{ font: 'var(--type-eyebrow)' }}>Belief </span>${snapshot?.belief ?? '—'}</div>
              <div><span style=${{ font: 'var(--type-eyebrow)' }}>Desire </span>${snapshot?.desire ?? '—'}</div>
              <div><span style=${{ font: 'var(--type-eyebrow)' }}>Intention </span>${snapshot?.intention ?? '—'}</div>
            </div>
          `}
    </article>
  `
}

interface KeeperChipProps {
  readonly entry: PinnedKeeperEntry
  readonly slot: KeeperBdiSlot
  readonly onFocus: (entry: PinnedKeeperEntry) => void
  readonly onUnpin: (keeperName: string) => void
}

function KeeperChip({ entry, slot, onFocus, onUnpin }: KeeperChipProps) {
  const tokens = slot.snapshot?.recent_token_spend?.[0]?.total_tokens ?? null
  return html`
    <span role="listitem" data-keeper=${entry.keeperName} style=${{ display: 'inline-flex', gap: '2px' }}>
      <button
        type="button"
        onClick=${() => onFocus(entry)}
        aria-label=${`focus ${entry.keeperName}`}
        style=${CHIP_BUTTON_STYLE}
      >
        <span>${entry.keeperName}</span>
        ${entry.line !== null ? html`<span style=${{ color: 'var(--color-fg-muted)' }}>L${entry.line}</span>` : null}
        ${tokens !== null ? html`<span style=${{ color: 'var(--color-fg-muted)' }}>${tokens.toLocaleString()}</span>` : null}
      </button>
      <button
        type="button"
        aria-label=${`unpin ${entry.keeperName}`}
        onClick=${() => onUnpin(entry.keeperName)}
        style=${{
          ...CHIP_BUTTON_STYLE,
          padding: '2px 6px',
        }}
      >
        ×
      </button>
    </span>
  `
}

function focusEntry(entry: PinnedKeeperEntry): void {
  pinKeeper(entry.keeperName, entry.line)
}

export function InspectorMultiKeeperBDI({ pollMs = 5000 }: { readonly pollMs?: number } = {}) {
  const entries = usePinnedKeepers()

  // Always invoke PIN_CAP hooks regardless of entries.length (Rules of Hooks).
  // Empty keeperName short-circuits the fetch effect.
  const slot0 = useKeeperBdiSnapshot(entries[0]?.keeperName ?? '', pollMs)
  const slot1 = useKeeperBdiSnapshot(entries[1]?.keeperName ?? '', pollMs)
  const slot2 = useKeeperBdiSnapshot(entries[2]?.keeperName ?? '', pollMs)
  const slot3 = useKeeperBdiSnapshot(entries[3]?.keeperName ?? '', pollMs)
  const slots: ReadonlyArray<KeeperBdiSlot> = [slot0, slot1, slot2, slot3]

  if (entries.length <= 1) {
    return html`<${InspectorKeeperBDI} pollMs=${pollMs} />`
  }

  const activeSlots = slots.slice(0, entries.length)
  const snapshots = activeSlots.map(s => s.snapshot)

  if (entries.length <= 3) {
    return html`
      <section
        role="list"
        aria-label="Keeper BDI multi-pin (compact-fold)"
        data-layout="compact-fold"
        data-pin-count=${entries.length}
        style=${MULTI_BDI_CONTAINER_STYLE}
      >
        <${RollupChip} snapshots=${snapshots} count=${entries.length} />
        ${entries.map((entry, idx) => html`
          <${KeeperPanel}
            key=${entry.keeperName}
            entry=${entry}
            slot=${activeSlots[idx] ?? EMPTY_SLOT}
            compact=${idx > 0}
            focused=${idx === 0}
            onUnpin=${unpinKeeper}
          />
        `)}
      </section>
    `
  }

  // entries.length === 4 (capped by PIN_CAP); focus-mode.
  const focused = entries[0]!
  const rest = entries.slice(1)

  return html`
    <section
      role="list"
      aria-label="Keeper BDI multi-pin (focus-mode)"
      data-layout="focus-mode"
      data-pin-count=${entries.length}
      style=${MULTI_BDI_CONTAINER_STYLE}
    >
      <${RollupChip} snapshots=${snapshots} count=${entries.length} />
      <${KeeperPanel}
        key=${focused.keeperName}
        entry=${focused}
        slot=${activeSlots[0] ?? EMPTY_SLOT}
        compact=${false}
        focused=${true}
        onUnpin=${unpinKeeper}
      />
      <div role="group" aria-label="other pinned keepers" style=${CHIP_GROUP_STYLE}>
        ${rest.map((entry, idx) => html`
          <${KeeperChip}
            key=${entry.keeperName}
            entry=${entry}
            slot=${activeSlots[idx + 1] ?? EMPTY_SLOT}
            onFocus=${focusEntry}
            onUnpin=${unpinKeeper}
          />
        `)}
      </div>
    </section>
  `
}

// Re-exported so consumers can guard `entries.length === PIN_CAP` without
// importing the store directly.
export { PIN_CAP }
