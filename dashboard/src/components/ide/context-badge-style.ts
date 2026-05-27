/**
 * Shared inline style for compact IDE context badges (route hop labels,
 * lane chips, persistence layer markers).
 *
 * Three sibling components — execute-output-drawer, ide-persistence-panel,
 * ide-branch-context-panel — defined this byte-for-byte. Lifting it here
 * makes the shared visual contract explicit, so a fourth panel needing
 * a context badge inherits the look instead of copy-pasting (and quietly
 * drifting on a token rename).
 *
 * If a panel needs a different look (e.g. overlay-keeper-trace ships its
 * own with `minWidth` + `lineHeight` for stacked layout), declare it
 * inline rather than mutating this constant.
 */
export const IDE_CONTEXT_BADGE_STYLE = {
  display: 'inline-flex',
  alignItems: 'center',
  height: '17px',
  padding: '0 5px',
  border: '1px solid var(--color-border-muted)',
  borderRadius: 'var(--r-1)',
  background: 'var(--color-bg-subtle)',
  color: 'var(--color-fg-muted)',
  fontFamily: 'var(--font-mono)',
  fontSize: 'var(--fs-9)',
  whiteSpace: 'nowrap',
} as const
