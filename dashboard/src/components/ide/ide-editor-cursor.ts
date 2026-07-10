import { html } from 'htm/preact'
import { getKeeperColor } from './keeper-cursor-overlay'
import {
  presenceEntries,
  type KeeperPresenceSnapshot,
  type KeeperPresenceStatus,
} from './keeper-presence-store'

export interface ActiveCursorInfo {
  keeper_id: string
  line: number
  tool_name?: string
  focus_mode: string
}

export function keepersWithCursorInFile(
  cursors: ReadonlyMap<
    string,
    { keeper_id: string; file_path: string; line: number; focus_mode: string; tool_name?: string }
  >,
  filePath: string,
): ReadonlyArray<ActiveCursorInfo> {
  const matches: ActiveCursorInfo[] = []
  for (const cursor of cursors.values()) {
    // Cursor stream defaults missing line numbers to 0; filter them so
    // the header chip never renders 'file:0' (the inspector applies the
    // same 1-based guard).
    if (cursor.file_path === filePath && cursor.line >= 1) {
      matches.push({
        keeper_id: cursor.keeper_id,
        line: cursor.line,
        tool_name: cursor.tool_name,
        focus_mode: cursor.focus_mode,
      })
    }
  }
  return matches.sort((a, b) => a.keeper_id.localeCompare(b.keeper_id))
}

export function EditorKeeperCursorChip(
  ac: ActiveCursorInfo,
  presence: KeeperPresenceSnapshot | null,
  key: string,
) {
  const color = getKeeperColor(ac.keeper_id)
  const status: KeeperPresenceStatus | undefined = presenceEntries(presence).find(
    e => e.keeper_id === ac.keeper_id,
  )?.status
  const isActive = status === 'active'
  return html`
    <li
      class="v2-ide-row"
      key=${key}
      title=${`${ac.keeper_id} L${ac.line}${ac.tool_name ? ` · ${ac.tool_name}` : ''} · ${ac.focus_mode}`}
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: '2px',
        fontSize: 'var(--fs-10)',
        fontFamily: 'var(--font-mono)',
        color: 'var(--color-fg-secondary)',
        padding: '0 4px',
        borderRadius: 'var(--r-1)',
        background: `${color.cursor}18`,
        whiteSpace: 'nowrap',
      }}
    >
      <span
        aria-hidden="true"
        style=${{
          width: '5px',
          height: '5px',
          borderRadius: '50%',
          background: color.cursor,
          display: 'inline-block',
          boxShadow: isActive ? `0 0 4px ${color.cursor}` : 'none',
        }}
      />
      <span>${ac.keeper_id}</span>
      <span style=${{ color: 'var(--color-fg-disabled)' }}>L${ac.line}</span>
    </li>
  `
}
