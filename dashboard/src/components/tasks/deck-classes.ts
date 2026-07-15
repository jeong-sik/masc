/**
 * Shared Tailwind class strings for the task/deck UI vocabulary.
 *
 * `kanban-components.ts` and `planning.ts` each defined
 * the same DECK_* primitives byte-for-byte. The vocabulary names a
 * common visual contract (deck container, body chip, section label,
 * meta text) so a token rename like `--color-border-strong` updates
 * every deck-shaped panel instead of silently drifting between sites.
 *
 * Scope:
 * - DECK_PANEL — outer container (overflow-hidden bordered surface)
 * - DECK_LABEL — section/group label (uppercase mono caps)
 * - DECK_META  — meta text (mono dim)
 * - DECK_CHIP  — inline body chip (mono mini-pill)
 *
 * `DECK_HEAD` stays file-local because the two definitions visibly
 * diverge: kanban uses a minimal border-b header while planning adds
 * flex/justify/gap and an inset shadow stripe. Locking that under one
 * SSOT would require deciding which header style is canonical — a
 * design call, not a refactor.
 */
export const DECK_PANEL =
  'overflow-hidden rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)]'

export const DECK_LABEL =
  'font-mono text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]'

export const DECK_META = 'font-mono text-3xs text-[var(--color-fg-disabled)]'

export const DECK_CHIP =
  'rounded-[var(--r-0)] border border-[var(--color-border-strong)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 font-mono text-3xs'
