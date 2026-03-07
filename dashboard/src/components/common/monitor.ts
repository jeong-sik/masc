// Shared monitor helpers — used by Overview, Execution, and related components

export type MonitorTone = 'ok' | 'warn' | 'bad'

export function toEpoch(value: string | number | null | undefined): number {
  if (value == null) return 0
  const parsed = typeof value === 'number' ? value : Date.parse(value)
  return Number.isNaN(parsed) ? 0 : parsed
}

export function toneRank(tone: MonitorTone): number {
  switch (tone) {
    case 'bad': return 2
    case 'warn': return 1
    default: return 0
  }
}

export function normalizeKey(value: string | null | undefined): string {
  return (value ?? '').trim().toLowerCase()
}

export function limitText(value: string | null | undefined, max = 96): string | null {
  const normalized = (value ?? '').replace(/\s+/g, ' ').trim()
  if (!normalized) return null
  return normalized.length > max ? `${normalized.slice(0, max - 3)}...` : normalized
}

export function taskPriorityValue(priority?: number | null): number {
  if (typeof priority !== 'number' || Number.isNaN(priority)) return 3
  return priority
}

export function taskPriorityLabel(priority?: number | null): string {
  const value = taskPriorityValue(priority)
  if (value <= 1) return 'P1'
  if (value === 2) return 'P2'
  if (value >= 4) return 'P4+'
  return 'P3'
}
