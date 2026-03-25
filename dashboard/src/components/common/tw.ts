// Reusable Tailwind class constants for frequently repeated patterns.
// Use these in new code to reduce duplication. Existing code may still use inline strings.

export const TW = {
  // Layout
  col4: 'flex flex-col gap-4',
  col3: 'flex flex-col gap-3',
  col2: 'flex flex-col gap-2',
  col1: 'flex flex-col gap-1.5',
  between: 'flex justify-between gap-3 items-start',
  section: 'section mb-4',

  // Text
  muted: 'text-[var(--text-muted)]',
  body: 'text-[var(--text-body)]',
  strong: 'text-[var(--text-strong)]',
  mutedXs: 'text-xs text-[var(--text-muted)]',
  mutedSm: 'text-[12px] text-[var(--text-muted)]',
  muted2xs: 'text-[11px] text-[var(--text-muted)]',
  mutedCaps: 'text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium',
  sectionTitle: 'text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider',

  // Card
  card: 'cmd-card rounded-xl-sub',
  emptyState: 'p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]',
  listRow: 'flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]',
} as const
