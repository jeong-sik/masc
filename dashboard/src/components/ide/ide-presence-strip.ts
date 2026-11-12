import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { useStoreSubscription } from './use-signal-value'
import { fetchIdePresence } from '../../api/ide'
import { KeeperBadge } from '../keeper-badge'
import {
  createKeeperPresenceStore,
  disconnectedSnapshot,
  globalPresenceSnapshot,
  LOADING_SNAPSHOT,
  normalizeKeeperPresenceSnapshot,
  type KeeperPresenceEntry,
  type KeeperPresenceSnapshot,
} from './keeper-presence-store'
import { setupObservationRefresh } from '../../lib/observation-refresh'

async function fetchPresence(signal: AbortSignal): Promise<KeeperPresenceSnapshot> {
  const raw = await fetchIdePresence({ signal })
  const snapshot = normalizeKeeperPresenceSnapshot(raw)
  if (snapshot === null) throw new Error('IDE presence returned an invalid snapshot')
  return snapshot
}

function presenceHeader(snap: KeeperPresenceSnapshot) {
  if (snap.kind === 'loading') {
    return html`
      <span style=${{ color: 'var(--color-fg-disabled)' }} aria-label="presence loading">○</span>
      <span style=${{ fontStyle: 'italic' }}>loading…</span>
    `
  }
  if (snap.kind === 'disconnected') {
    return html`
      <span style=${{ color: 'var(--color-status-err)' }} aria-label=${`presence disconnected: ${snap.reason}`}>○</span>
      <span style=${{ fontStyle: 'italic' }}>disconnected (${snap.reason})</span>
    `
  }
  const segments = [snap.runtime_id]
  if (snap.branch !== undefined) segments.push(snap.branch)
  if (snap.supervisor !== undefined) segments.push(snap.supervisor)
  return html`
    <span style=${{ color: 'var(--color-status-ok)' }} aria-label="presence live">●</span>
    ${segments.map((seg, idx) => html`
      ${idx > 0 ? html`<span>/</span>` : null}
      <span>${seg}</span>
    `)}
  `
}

function samePresence(a: KeeperPresenceSnapshot, b: KeeperPresenceSnapshot): boolean {
  if (a.kind !== b.kind) return false
  if (a.kind === 'loading') return true
  if (a.kind === 'disconnected') return b.kind === 'disconnected' && a.reason === b.reason
  if (b.kind !== 'live') return false
  return a.runtime_id === b.runtime_id
    && a.branch === b.branch
    && a.supervisor === b.supervisor
    && a.entries.length === b.entries.length
    && a.entries.every((entry, i) => {
      const other = b.entries[i]!
      return entry.keeper_id === other.keeper_id
        && entry.workspace_label === other.workspace_label
        && entry.role === other.role
        && entry.status === other.status
        && entry.last_seen_ms === other.last_seen_ms
    })
}

/**
 * The strip is mounted unconditionally in the IDE shell header, so it owns
 * the presence fetch for the whole IDE: every read lands in
 * {@link globalPresenceSnapshot}, which the interject pill, the activity
 * lens, the conversation rail, the persistence map and the editor read.
 * A snapshot kept only in this component's store left all of those on
 * `loading` for the life of the page.
 */
export function IdePresenceStrip({
  compact = false,
}: { readonly compact?: boolean } = {}) {
  const presenceStore = useMemo(() => createKeeperPresenceStore(), [])

  useEffect(() => setupObservationRefresh(async signal => {
    try {
      const snapshot = await fetchPresence(signal)
      // Unchanged observations leave every downstream presence consumer alone.
      if (!signal.aborted && !samePresence(globalPresenceSnapshot.value, snapshot)) {
        globalPresenceSnapshot.value = snapshot
      }
    } catch (error) {
      if (signal.aborted) return
      globalPresenceSnapshot.value = disconnectedSnapshot('fetch_failed')
      throw error
    }
  }, { topics: ['ide_presence'], resetRead: () => {
    globalPresenceSnapshot.value = LOADING_SNAPSHOT
    presenceStore.reset()
  } }), [presenceStore])

  useEffect(() => {
    const unsub = globalPresenceSnapshot.subscribe(() => {
      presenceStore.seed(globalPresenceSnapshot.value)
    })
    return unsub
  }, [presenceStore])

  useStoreSubscription(presenceStore.subscribe)

  const current = presenceStore.snapshot()
  const entries = presenceStore.entries()

  if (compact) {
    const compactStateLabel = current.kind === 'live'
      ? `Presence live: ${current.runtime_id}`
      : current.kind === 'disconnected'
        ? `Presence disconnected: ${current.reason}`
        : 'Presence loading'
    return html`
      <div
        class="ide-presence-strip ide-presence v2-ide-panel"
        role="status"
        aria-label="Live workspace keeper presence"
        data-state=${current.kind}
      >
        <span class="lbl">Presence</span>
        <span
          class="ide-v2-presence-state"
          data-state=${current.kind}
          aria-label=${compactStateLabel}
          title=${compactStateLabel}
        >${current.kind === 'live' ? '●' : '○'}</span>
        <ul>
          ${entries.map(entry => html`
            <li
              key=${entry.keeper_id}
              title=${`${entry.keeper_id} · ${entry.role} · ${entry.workspace_label}`}
              aria-label=${`${entry.keeper_id} ${entry.status} in ${entry.workspace_label}`}
            >
              <${KeeperBadge}
                id=${entry.keeper_id}
                variant="sigil"
                size="sm"
                beat=${entry.status === 'active'}
              />
            </li>
          `)}
        </ul>
      </div>
    `
  }

  return html`
    <div
      class="ide-presence-strip v2-ide-panel"
      role="status"
      aria-label="Live workspace keeper presence"
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--sp-2)',
        minWidth: 0,
        color: 'var(--color-fg-muted)',
      }}
    >
      ${presenceHeader(current)}
      <ul
        style=${{
          display: 'inline-flex',
          alignItems: 'center',
          gap: 'var(--sp-2)',
          listStyle: 'none',
          margin: 0,
          padding: 0,
          minWidth: 0,
          overflow: 'hidden',
        }}
      >
        ${entries.map(entry => html`<${PresenceChip} entry=${entry} />`)}
      </ul>
    </div>
  `
}

interface PresenceChipProps {
  readonly entry: KeeperPresenceEntry
}

function PresenceChip({ entry }: PresenceChipProps) {
  const isActive = entry.status === 'active'

  return html`
    <li
      class="ide-presence-chip v2-ide-row"
      title=${`${entry.keeper_id} · ${entry.role}`}
      aria-label=${`${entry.keeper_id} ${entry.status} in ${entry.workspace_label}`}
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--sp-1)',
        maxWidth: '260px',
        color: 'var(--color-fg-secondary)',
        whiteSpace: 'nowrap',
        borderRadius: 'var(--r-1)',
        padding: '0 var(--sp-1)',
        transition: 'background 0.15s',
      }}
    >
      <${KeeperBadge} id=${entry.keeper_id} variant="sigil" size="sm" beat=${isActive} />
      <span style=${{ overflow: 'hidden', textOverflow: 'ellipsis' }}>
        ${entry.keeper_id}@${entry.workspace_label}
      </span>
      <span
        style=${{
          color: isActive ? 'var(--color-status-ok)' : 'var(--color-fg-muted)',
          fontSize: 'var(--fs-10)',
        }}
      >
        ${entry.status}
      </span>
    </li>
  `
}

export function prLabel(prNumber: number, prState: string | null): string {
  if (prState === 'open') return `#${prNumber}`
  if (prState === 'closed') return `#${prNumber}✕`
  if (prState === 'merged') return `#${prNumber}✓`
  return `#${prNumber}`
}
