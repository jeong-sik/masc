/** Inline styles shared by the two views of Runtime → Prompts. */

/** A text input or select. */
export const fieldStyle = {
  padding: 'var(--sp-1) var(--sp-2)',
  background: 'var(--input-bg)',
  border: '1px solid var(--input-border)',
  borderRadius: 'var(--radius-sm)',
} as const

/** A secondary line of text. */
export const noteStyle = { fontSize: 'var(--fs-12)', color: 'var(--fg-2)' } as const
