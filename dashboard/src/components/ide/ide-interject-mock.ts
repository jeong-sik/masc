import { html } from 'htm/preact'

// PR-2 placeholder for the INTERJECT input. The real wiring (input
// store + active-keeper resolution + Send/Approve/Pause/Drain action
// dispatch through keeper-actions.ts) lands in Phase 2 PR-7.

const ACTIONS: ReadonlyArray<{ id: string; label: string; primary: boolean }> = [
  { id: 'send', label: 'Send', primary: true },
  { id: 'approve', label: 'Approve', primary: false },
  { id: 'pause', label: 'Pause', primary: false },
  { id: 'drain', label: 'Drain', primary: false },
]

export function IdeInterjectMock() {
  return html`
    <div
      role="region"
      aria-label="INTERJECT (mock — PR-7 replaces with active-keeper wiring)"
      style=${{
        display: 'grid',
        gridTemplateColumns: 'auto 1fr auto',
        gap: 'var(--sp-2)',
        padding: 'var(--sp-2) var(--sp-3)',
        background: 'var(--color-bg-elevated)',
        borderTop: '1px solid var(--color-border-default)',
        alignItems: 'center',
      }}
    >
      <span
        style=${{
          font: 'var(--type-eyebrow)',
          color: 'var(--color-fg-muted)',
          padding: '0 var(--sp-2)',
        }}
      >INTERJECT</span>
      <input
        type="text"
        placeholder="Send message to active keeper..."
        aria-label="Interject input (mock)"
        readOnly
        style=${{
          width: '100%',
          padding: 'var(--sp-2)',
          background: 'var(--color-bg-page)',
          color: 'var(--color-fg-secondary)',
          border: '1px solid var(--color-border-default)',
          borderRadius: 'var(--r-1)',
          font: 'var(--type-body)',
        }}
      />
      <div style=${{ display: 'flex', gap: 'var(--sp-1)' }}>
        ${ACTIONS.map(action => html`
          <button
            type="button"
            disabled
            aria-label=${`${action.label} (mock — PR-7 wires action)`}
            style=${{
              padding: '6px 12px',
              background: action.primary ? 'var(--color-accent-fg)' : 'var(--color-bg-surface)',
              color: action.primary ? 'var(--color-bg-page)' : 'var(--color-fg-secondary)',
              border: action.primary ? 'none' : '1px solid var(--color-border-default)',
              borderRadius: 'var(--r-1)',
              font: 'var(--type-body)',
              cursor: 'not-allowed',
              opacity: 0.85,
            }}
          >${action.label}</button>
        `)}
      </div>
    </div>
  `
}
