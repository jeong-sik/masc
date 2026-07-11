import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { activeIdeFile, focusIdeContextAnchor } from './ide-state'
import { cursorOverlaySignal, getKeeperColor, type KeeperCursor } from './keeper-cursor-overlay'
import { routeLinksForContext } from './ide-context-lens'

const FILE_ICONS: Readonly<Record<string, string>> = {
  '.ts': '🟦', '.tsx': '🟦',
  '.js': '🟨', '.jsx': '🟨',
  '.py': '🐍', '.ml': '🐫', '.mli': '🐫',
  '.rs': '🦀', '.go': '🔵',
  '.json': '📋', '.md': '📝',
  '.html': '🌐', '.css': '🎨',
  '.toml': '⚙️', '.yaml': '⚙️', '.yml': '⚙️',
}

export function IdeBreadcrumb() {
  const [filePath, setFilePath] = useState(activeIdeFile.value)
  useEffect(() => {
    const unsub = activeIdeFile.subscribe(f => setFilePath(f))
    return () => unsub()
  }, [])

  const [overlay, setOverlay] = useState(cursorOverlaySignal.value)
  useEffect(() => {
    const unsub = cursorOverlaySignal.subscribe(v => setOverlay(v))
    return () => unsub()
  }, [])

  if (filePath === null) {
    return html`
      <nav
        aria-label="Editor breadcrumb (no file)"
        style=${{ color: 'var(--color-fg-disabled)', fontStyle: 'italic' }}
      >no active file</nav>
    `
  }
  const segments = filePath.split('/')
  const fileName = segments.at(-1) ?? ""
  const ext = fileName.includes('.') ? fileName.slice(fileName.lastIndexOf('.')) : ''
  const icon = FILE_ICONS[ext] ?? '📄'

  const activeOnFile: Array<{
    readonly keeperId: string
    readonly color: string
    readonly focusMode: KeeperCursor['focus_mode']
    readonly toolName: string | undefined
    readonly turn: number | undefined
    readonly line: number
  }> = []
  for (const [keeperId, cursor] of overlay.cursors) {
    if (cursor.file_path === filePath) {
      activeOnFile.push({
        keeperId,
        color: getKeeperColor(keeperId).cursor,
        focusMode: cursor.focus_mode,
        toolName: cursor.tool_name,
        turn: cursor.turn,
        line: cursor.line,
      })
    }
  }

  const activateKeeperBreadcrumb = (keeper: (typeof activeOnFile)[number]) => {
    focusIdeContextAnchor({
      file_path: filePath,
      line: keeper.line,
      surface: 'Keeper',
      label: keeper.toolName ?? keeper.focusMode,
      source_id: `breadcrumb:${keeper.keeperId}:${keeper.line}`,
      keeper_id: keeper.keeperId,
      route_links: routeLinksForContext({
        filePath,
        line: keeper.line,
        surface: 'Keeper',
        label: keeper.toolName ?? keeper.focusMode,
        sourceId: `breadcrumb:${keeper.keeperId}:${keeper.line}`,
        keeperId: keeper.keeperId,
      }),
    }, 'operator')
  }

  return html`
    <div
      role="navigation"
      aria-label="File breadcrumb"
      data-testid="ide-breadcrumb"
      class="ide-breadcrumb v2-ide-toolbar ide-v2-crumb flex items-center gap-1.5 border-b border-[var(--color-border-divider)] bg-[var(--color-bg-elevated)] px-3 py-1 font-mono text-2xs"
    >
      <span aria-hidden="true" style=${{ fontSize: '12px', lineHeight: '16px' }}>${icon}</span>
      <span
        class="flex min-w-0 items-center gap-0.5 text-[var(--color-fg-secondary)]"
        style=${{ overflow: 'hidden' }}
      >
        ${segments.map((seg, i) => html`
          ${i > 0 ? html`<span class="text-[var(--color-fg-disabled)]">/</span>` : null}
          <span
            class=${`seg ${i === segments.length - 1 ? 'last' : ''} ${i === segments.length - 1 ? 'text-[var(--color-fg-primary)]' : ''}`}
            style=${{ whiteSpace: 'nowrap' }}
          >${seg}</span>
        `)}
      </span>
      ${activeOnFile.length > 0
        ? html`
          <span class="flex items-center gap-1 ml-auto shrink-0">
            ${activeOnFile.map(k => html`
              <button
                key=${k.keeperId}
                type="button"
                class="ide-breadcrumb-keeper v2-ide-action"
                title=${`${k.keeperId} · ${k.focusMode}${k.toolName ? ` · ${k.toolName}` : ''}${k.turn != null ? ` · turn ${k.turn}` : ''}`}
                aria-label=${`Focus ${k.keeperId} keeper context at line ${k.line}`}
                onClick=${() => activateKeeperBreadcrumb(k)}
                style=${{ color: 'var(--color-fg-muted)' }}
              >
                <span
                  aria-hidden="true"
                  style=${{
                    width: '7px',
                    height: '7px',
                    borderRadius: '50%',
                    background: k.color,
                    display: 'inline-block',
                    boxShadow: k.focusMode === 'editing' ? `0 0 4px ${k.color}` : 'none',
                  }}
                />
                <span>${k.keeperId}</span>
                ${k.toolName ? html`<span class="text-[var(--color-fg-disabled)]" style=${{ fontSize: '10px' }}>${k.toolName}</span>` : null}
                ${k.turn != null ? html`<span style=${{ fontSize: '10px', color: 'var(--color-accent-fg)' }}>T${k.turn}</span>` : null}
              </button>
            `)}
          </span>
        `
        : null}
    </div>
  `
}
