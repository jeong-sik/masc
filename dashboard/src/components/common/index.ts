// Barrel for the converged tone-indicator family. `<Pill>` is the canonical
// entry for new code and migrated forks; the other three are kept primitives
// (StatusChip shares the Pill engine; CountBadge + StatusBadge are a separate
// styling lineage reconciled later — see docs/design/dashboard-pill-convergence.md).

export {
  Pill,
  pillClasses,
  isPillTone,
  summarizePill,
  type PillTone,
  type PillProps,
  type PillClassOptions,
  type PillSummary,
} from './pill'

export {
  StatusChip,
  statusChipClasses,
  isSemanticTone,
  keeperStateTone,
  summarizeStatusChip,
  type StatusChipTone,
  type StatusChipProps,
} from './status-chip'

export {
  CountBadge,
  countBadgeClasses,
  summarizeCountBadge,
  type BadgeTone,
  type CountBadgeProps,
} from './badge'

export {
  StatusBadge,
  statusBadgeTone,
  statusDotColor,
} from './status-badge'
