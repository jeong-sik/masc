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

/**
 * Base style for *inline* IDE context badges that sit inside flowing text
 * (the presence strip's per-keeper chip, the conversation rail's context
 * label). Same mono-font visual treatment as the blocky badge above, but
 * without explicit display/alignItems/height — these chips render at the
 * surrounding line height.
 *
 * Callers spread this base and supply their own `background` token because
 * the two known sites pick different surfaces (`bg-elevated` for toolbars,
 * `bg-surface` for the rail). All other 6 properties stay locked here so
 * a token rename (e.g. `--color-border-default`) updates both sites.
 */
export const IDE_INLINE_BADGE_BASE = {
  fontSize: 'var(--fs-9)',
  padding: '0 3px',
  border: '1px solid var(--color-border-default)',
  borderRadius: 'var(--r-0)',
  color: 'var(--color-fg-muted)',
  fontFamily: 'var(--font-mono)',
} as const
