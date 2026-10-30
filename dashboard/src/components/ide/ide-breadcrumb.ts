import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { activeIdeFile } from './ide-state'

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

  return html`
    <div
      role="navigation"
      aria-label="File breadcrumb"
      data-testid="ide-breadcrumb"
      class="ide-breadcrumb v2-ide-toolbar ide-crumb flex items-center gap-1.5 border-b border-[var(--color-border-divider)] bg-[var(--color-bg-elevated)] px-3 py-1 font-mono text-2xs"
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
    </div>
  `
}
