import { html } from 'htm/preact'
import { IdeExplorerMock } from './ide-explorer-mock'
import { IdeEditorMock } from './ide-editor-mock'
import { IdeConversationRailMock } from './ide-conversation-rail-mock'
import { IdeActivityMock } from './ide-activity-mock'
import { IdeInterjectMock } from './ide-interject-mock'

// PR-2: 4-pane CODE mode shell with mock content. Layout matches the
// cockpit IdePlane prototype's grid (`design-system/ui_kits/cockpit/
// cockpit.css` `.ide-v2-tree / .ide-v2-center / .ide-v2-right /
// .ide-v2-terminal`); production tokens are v0.4 Semantic-tier only.
//
// Each child mock cites the implementation PR that replaces it:
//   EXPLORER          -> Phase 2 PR-4 (file-tree-store, RFC 0014)
//   editor            -> Phase 2 PR-5 (Shiki + RFC 0019 blame)
//   CONVERSATION rail -> Phase 2 PR-6 (RFC 0021)
//   ACTIVITY          -> Phase 2 PR-6 (sse-store-backed stream)
//   INTERJECT         -> Phase 2 PR-7 (keeper-actions wiring)
//
// Audit reference:
//   dashboard/design-system/audits/2026-04-30-ide-mockup-vs-v0.4-mapping.md

export function IdeShell() {
  return html`
    <section
      class="ide-plane-shell"
      role="region"
      aria-label="Code IDE shell (Phase 1 PR-2 — mock content)"
      style=${{
        display: 'grid',
        gridTemplateRows: 'auto 1fr auto',
        background: 'var(--color-bg-page)',
        color: 'var(--color-fg-primary)',
        minHeight: 'calc(100vh - var(--h-topbar) - var(--h-kpi))',
      }}
    >
      <header
        style=${{
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--sp-3)',
          padding: 'var(--sp-2) var(--sp-3)',
          background: 'var(--color-bg-surface)',
          borderBottom: '1px solid var(--color-border-default)',
          font: 'var(--type-eyebrow)',
          color: 'var(--color-fg-muted)',
        }}
      >
        <span style=${{ color: 'var(--color-fg-secondary)' }}>코드 IDE</span>
        <span>·</span>
        <span>* runtime / main / nick0cave@dkr-a1 / improver@wt-run-47</span>
        <span style=${{ marginLeft: 'auto', color: 'var(--color-status-ok, var(--ok))' }}>● mcp · connected</span>
      </header>
      <div
        class="ide-plane-grid"
        role="presentation"
        style=${{
          display: 'grid',
          gridTemplateColumns: 'minmax(180px, 220px) minmax(0, 1fr) minmax(280px, 320px)',
          gridTemplateRows: '1fr auto',
          minHeight: 0,
        }}
      >
        <div style=${{ gridColumn: 1, gridRow: '1 / span 2' }}>
          <${IdeExplorerMock} />
        </div>
        <div style=${{ gridColumn: 2, gridRow: '1 / span 2', minHeight: 0 }}>
          <${IdeEditorMock} />
        </div>
        <div style=${{ gridColumn: 3, gridRow: 1, minHeight: 0 }}>
          <${IdeConversationRailMock} />
        </div>
        <div style=${{ gridColumn: 3, gridRow: 2, minHeight: 0 }}>
          <${IdeActivityMock} />
        </div>
      </div>
      <${IdeInterjectMock} />
    </section>
  `
}
