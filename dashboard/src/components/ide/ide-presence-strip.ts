import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import {
  createKeeperPresenceStore,
  type KeeperPresenceEntry,
  type KeeperPresenceSnapshot,
} from './keeper-presence-store'

export const IDE_MOCK_PRESENCE: KeeperPresenceSnapshot = {
  runtime_id: 'runtime',
  branch: 'main',
  supervisor: 'local',
  connected: true,
  entries: [
    {
      keeper_id: 'nick0cave',
      workspace_label: 'dkr-a1',
      branch: 'main',
      role: 'driver',
      status: 'active',
      last_seen_ms: Date.UTC(2026, 4, 2, 1, 43, 18),
    },
    {
      keeper_id: 'masc-improver',
      workspace_label: 'wt-run-47',
      branch: 'feature/normalize-tools',
      role: 'improver',
      status: 'active',
      last_seen_ms: Date.UTC(2026, 4, 2, 1, 42, 58),
    },
  ],
}

interface IdePresenceStripProps {
  readonly snapshot?: KeeperPresenceSnapshot
}

export function IdePresenceStrip({
  snapshot = IDE_MOCK_PRESENCE,
}: IdePresenceStripProps) {
  const presenceStore = useMemo(() => createKeeperPresenceStore(snapshot), [])
  const [, forceRender] = useState(0)

  useEffect(() => presenceStore.subscribe(() => forceRender(tick => tick + 1)), [presenceStore])
  useEffect(() => {
    presenceStore.seed(snapshot)
  }, [presenceStore, snapshot])

  const current = presenceStore.snapshot()
  const entries = presenceStore.entries()

  return html`
    <div
      role="status"
      aria-label="IDE keeper presence"
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--sp-2)',
        minWidth: 0,
        color: 'var(--color-fg-muted)',
      }}
    >
      <span style=${{ color: current.connected ? 'var(--color-status-ok, var(--ok))' : 'var(--color-fg-disabled)' }}>●</span>
      <span>${current.runtime_id}</span>
      <span>/</span>
      <span>${current.branch}</span>
      <span>/</span>
      <span>${current.supervisor}</span>
      <ul
        style=${{
          display: 'inline-flex',
          alignItems: 'center',
          gap: 'var(--sp-2)',
          listStyle: 'none',
          margin: 0,
          padding: 0,
          minWidth: 0,
        }}
      >
        ${entries.map(entry => html`<${PresenceChip} entry=${entry} />`)}
      </ul>
    </div>
  `
}

function PresenceChip({ entry }: { readonly entry: KeeperPresenceEntry }) {
  const hue = keeperHueIndex(entry.keeper_id)
  const keeperColor = `var(--color-keeper-${hue}-glow, var(--k-${hue}))`
  return html`
    <li
      title=${`${entry.keeper_id} · ${entry.role} · ${entry.branch}`}
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--sp-1)',
        maxWidth: '180px',
        color: 'var(--color-fg-secondary)',
        whiteSpace: 'nowrap',
      }}
    >
      <span
        aria-hidden="true"
        style=${{
          width: '6px',
          height: '6px',
          borderRadius: '50%',
          background: keeperColor,
          opacity: entry.status === 'active' ? 0.95 : 0.45,
          flex: '0 0 auto',
        }}
      />
      <span style=${{ overflow: 'hidden', textOverflow: 'ellipsis' }}>
        ${entry.keeper_id}@${entry.workspace_label}
      </span>
    </li>
  `
}
