/**
 * KeeperLineOwnership — framework-agnostic accumulator for RFC 0019.
 *
 * Consumers feed keeper edit events for one active file. The accumulator
 * derives the latest owner per 1-indexed line plus the event history for each
 * line. UI adapters can render a blame gutter without duplicating the
 * line-range expansion or hue mapping rules.
 */

import { kSlot, type AgentColorSlot } from './agent-presence'

export type KeeperEditKind = 'edit' | 'create' | 'refactor' | 'revert'

export interface KeeperEdit {
  readonly file_path: string
  readonly line_start: number
  readonly line_end: number
  readonly keeper_id: string
  readonly timestamp_ms: number
  readonly kind: KeeperEditKind
}

export interface LineOwnership {
  readonly keeper_id: string
  readonly hue_index: AgentColorSlot
  readonly last_edit_kind: KeeperEditKind
  readonly last_edit_ms: number
}

export interface KeeperLineOwnershipAccumulator {
  readonly filePath: () => string
  readonly ownership: () => ReadonlyMap<number, LineOwnership>
  readonly eventsForLine: (line: number) => ReadonlyArray<KeeperEdit>
  readonly knownKeepers: () => ReadonlyArray<string>
  readonly ingest: (event: KeeperEdit) => boolean
  readonly reset: (filePath?: string) => void
}

export function keeperHueIndex(keeperId: string): AgentColorSlot {
  return kSlot(keeperId)
}

function validLineRange(event: KeeperEdit): { start: number; end: number } | null {
  if (!Number.isSafeInteger(event.line_start) || !Number.isSafeInteger(event.line_end)) return null
  const start = event.line_start
  const end = event.line_end
  if (start < 1 || end < 1 || end < start) return null
  return { start, end }
}

function validTimestamp(event: KeeperEdit): boolean {
  return Number.isFinite(event.timestamp_ms)
}

function shouldReplace(existing: LineOwnership | undefined, event: KeeperEdit): boolean {
  if (existing === undefined) return true
  return event.timestamp_ms >= existing.last_edit_ms
}

export function createKeeperLineOwnershipAccumulator(
  initialFilePath: string,
): KeeperLineOwnershipAccumulator {
  let activeFilePath = initialFilePath
  const ownershipByLine = new Map<number, LineOwnership>()
  const eventsByLine = new Map<number, KeeperEdit[]>()
  const keepers = new Set<string>()

  const filePath = (): string => activeFilePath
  const ownership = (): ReadonlyMap<number, LineOwnership> => new Map(ownershipByLine)
  const eventsForLine = (line: number): ReadonlyArray<KeeperEdit> =>
    Number.isSafeInteger(line) ? [...(eventsByLine.get(line) ?? [])] : []
  const knownKeepers = (): ReadonlyArray<string> => [...keepers].sort()

  const ingest = (event: KeeperEdit): boolean => {
    if (event.file_path !== activeFilePath) return false
    if (!validTimestamp(event)) return false
    const range = validLineRange(event)
    if (range === null) return false

    keepers.add(event.keeper_id)
    const next: LineOwnership = Object.freeze({
      keeper_id: event.keeper_id,
      hue_index: keeperHueIndex(event.keeper_id),
      last_edit_kind: event.kind,
      last_edit_ms: event.timestamp_ms,
    })

    for (let line = range.start; line <= range.end; line += 1) {
      const history = eventsByLine.get(line)
      if (history) history.push(event)
      else eventsByLine.set(line, [event])

      if (shouldReplace(ownershipByLine.get(line), event)) {
        ownershipByLine.set(line, next)
      }
    }
    return true
  }

  const reset = (filePath?: string): void => {
    if (filePath !== undefined) activeFilePath = filePath
    ownershipByLine.clear()
    eventsByLine.clear()
    keepers.clear()
  }

  return {
    filePath,
    ownership,
    eventsForLine,
    knownKeepers,
    ingest,
    reset,
  }
}
