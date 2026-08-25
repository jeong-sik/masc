/**
 * Keeper Cursor Overlay — Multi-keeper observation layer
 * Enhanced with precise cursor positions from keeper activity
 */

import { signal } from '@preact/signals'
import { fetchIdeCursors, type IdeScope } from '../../api/ide'
import { registerIdeCursorRefresh } from '../../sse-store'

// ── Types ─────────────────────────────────────────────────────────

export interface KeeperCursor {
  keeper_id: string
  file_path: string
  line: number
  column: number
  selection_end?: { line: number; column: number }
  focus_mode: 'reading' | 'editing' | 'reviewing' | 'planning'
  last_update: number
  tool_name?: string
  turn?: number
}

export interface KeeperCursorOverlay {
  cursors: Map<string, KeeperCursor>
  heatmap: Map<number, number>
  collisions: Array<{
    line: number
    keeper_ids: string[]
  }>
  active_file: string | null
  stream?: KeeperCursorStreamState
}

export type KeeperCursorStreamStatus = 'connecting' | 'live' | 'degraded' | 'closed'

export interface KeeperCursorStreamState {
  readonly status: KeeperCursorStreamStatus
  readonly failedCount: number
  readonly lastOpenMs?: number
  readonly lastErrorMs?: number
  readonly error?: string
}

export interface KeeperCursorStreamOptions {
  readonly scope?: IdeScope | null
  /** RFC-0378 §5.3b: the canonical codebase slug — the one wire key. */
  readonly codebase?: string | null
  readonly onStatus?: (state: KeeperCursorStreamState) => void
}

// ── Signals ──────────────────────────────────────────────────────

export const cursorOverlaySignal = signal<KeeperCursorOverlay>({
  cursors: new Map(),
  heatmap: new Map(),
  collisions: [],
  active_file: null,
})

// ── Keeper Color Mapping ─────────────────────────────────────────

export interface KeeperCursorColor {
  readonly slot: number
  readonly cursor: string
  readonly selection: string
  readonly glow: string
  readonly text: string
  readonly shadow: string
}

const KEEPER_COLOR_SLOT_COUNT = 12

function keeperColorSlot(keeperId: string, index?: number): number {
  if (Number.isSafeInteger(index) && index! >= 0) return (index! % KEEPER_COLOR_SLOT_COUNT) + 1

  let hash = 2166136261
  for (let i = 0; i < keeperId.length; i += 1) {
    hash ^= keeperId.charCodeAt(i)
    hash = Math.imul(hash, 16777619)
  }
  return (Math.abs(hash) % KEEPER_COLOR_SLOT_COUNT) + 1
}

export function getKeeperColor(keeperId: string, index?: number): KeeperCursorColor {
  const slot = keeperColorSlot(keeperId, index)
  const glow = `var(--color-keeper-${slot}-glow)`
  return {
    slot,
    cursor: `var(--color-keeper-${slot})`,
    selection: `rgb(${glow} / 0.22)`,
    glow,
    text: 'var(--color-bg-page)',
    shadow: `0 0 0 1px rgb(${glow} / 0.32), 0 2px 6px rgb(${glow} / 0.20)`,
  }
}

// ── Collision Detection ─────────────────────────────────────────

export function detectCollisions(cursors: Iterable<KeeperCursor>): Array<{
  line: number
  keeper_ids: string[]
}> {
  const lineToKeepers = new Map<number, string[]>()
  
  for (const cursor of cursors) {
    const lines = cursor.selection_end
      ? range(cursor.line, cursor.selection_end.line)
      : [cursor.line]
    
    for (const line of lines) {
      const existing = lineToKeepers.get(line) || []
      if (!existing.includes(cursor.keeper_id)) {
        existing.push(cursor.keeper_id)
        lineToKeepers.set(line, existing)
      }
    }
  }
  
  const collisions: Array<{ line: number; keeper_ids: string[] }> = []
  
  lineToKeepers.forEach((keepers, line) => {
    if (keepers.length > 1) {
      collisions.push({ line, keeper_ids: keepers })
    }
  })
  
  return collisions.sort((a, b) => b.keeper_ids.length - a.keeper_ids.length)
}

function range(start: number, end: number): number[] {
  const result: number[] = []
  for (let i = Math.min(start, end); i <= Math.max(start, end); i++) {
    result.push(i)
  }
  return result
}

// ── Heatmap Calculation ─────────────────────────────────────────

export function calculateHeatmap(cursors: Iterable<KeeperCursor>, windowMs = 60000): Map<number, number> {
  const heatmap = new Map<number, number>()
  const now = Date.now()
  
  for (const cursor of cursors) {
    if (now - cursor.last_update > windowMs) continue
    
    const lines = cursor.selection_end
      ? range(cursor.line, cursor.selection_end.line)
      : [cursor.line]
    
    for (const line of lines) {
      const current = heatmap.get(line) || 0
      heatmap.set(line, current + 1)
    }
  }
  
  return heatmap
}

// ── WebSocket Push Integration ──────────────────────────────────

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function stringField(record: Record<string, unknown>, key: string): string | null {
  const value = record[key]
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

function numberField(record: Record<string, unknown>, key: string): number | null {
  const value = record[key]
  if (typeof value === 'number' && Number.isFinite(value)) return value
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

function focusModeField(record: Record<string, unknown>): KeeperCursor['focus_mode'] | null {
  const value = stringField(record, 'focus_mode')
  if (value === 'reading' || value === 'editing' || value === 'reviewing' || value === 'planning') {
    return value
  }
  return null
}

function parseSelectionEnd(raw: unknown): KeeperCursor['selection_end'] | null {
  if (!isRecord(raw)) return null
  const line = numberField(raw, 'line')
  const column = numberField(raw, 'column')
  if (line === null || line < 1 || column === null || column < 0) return null
  return { line, column }
}

function parseCursorEntry(raw: unknown): KeeperCursor | null {
  if (!isRecord(raw)) return null
  const keeperId = stringField(raw, 'keeper_id')
  const filePath = stringField(raw, 'file_path')
  const line = numberField(raw, 'line')
  const column = numberField(raw, 'column')
  const focusMode = focusModeField(raw)
  const lastUpdate = numberField(raw, 'last_update')
  if (
    !keeperId
    || !filePath
    || line === null
    || line < 1
    || column === null
    || column < 0
    || focusMode === null
    || lastUpdate === null
  ) return null

  const selectionEnd = parseSelectionEnd(raw.selection_end)
  const toolName = stringField(raw, 'tool_name')
  const turn = numberField(raw, 'turn')
  return {
    keeper_id: keeperId,
    file_path: filePath,
    line,
    column,
    ...(selectionEnd ? { selection_end: selectionEnd } : {}),
    focus_mode: focusMode,
    last_update: lastUpdate,
    ...(toolName ? { tool_name: toolName } : {}),
    ...(turn !== null ? { turn } : {}),
  }
}

export function normalizeKeeperCursorSnapshot(snapshot: unknown): KeeperCursorOverlay {
  const entries =
    isRecord(snapshot) && Array.isArray(snapshot.cursors)
      ? snapshot.cursors
      : isRecord(snapshot) && Array.isArray(snapshot.entries)
        ? snapshot.entries
        : []
  const cursors = new Map<string, KeeperCursor>()
  let activeFilePath: string | null = null

  for (const raw of entries) {
    const cursor = parseCursorEntry(raw)
    if (cursor === null) continue
    if (!activeFilePath) activeFilePath = cursor.file_path
    cursors.set(cursor.keeper_id, cursor)
  }

  return {
    cursors,
    heatmap: calculateHeatmap(cursors.values()),
    collisions: detectCollisions(cursors.values()),
    active_file: activeFilePath,
  }
}

export function connectKeeperCursorPush(
  onUpdate: (overlay: KeeperCursorOverlay) => void,
  options: KeeperCursorStreamOptions = {},
): () => void {
  let failedCount = 0
  let closed = false
  let inFlight = false
  let refreshAgain = false
  options.onStatus?.({ status: 'connecting', failedCount })

  const refresh = async (): Promise<void> => {
    if (closed) return
    if (inFlight) {
      refreshAgain = true
      return
    }
    inFlight = true
    try {
      const snapshot = await fetchIdeCursors({
        scope: options.scope,
        codebase: options.codebase,
      })
      if (closed) return
      onUpdate(normalizeKeeperCursorSnapshot(snapshot))
      failedCount = 0
      options.onStatus?.({ status: 'live', failedCount, lastOpenMs: Date.now() })
    } catch (error) {
      if (closed) return
      failedCount += 1
      const message = error instanceof Error ? error.message : String(error)
      options.onStatus?.({
        status: 'degraded',
        failedCount,
        lastErrorMs: Date.now(),
        error: message,
      })
      console.error('Keeper cursor refresh error:', error)
    } finally {
      inFlight = false
      if (refreshAgain && !closed) {
        refreshAgain = false
        void refresh()
      }
    }
  }

  const unregister = registerIdeCursorRefresh(() => { void refresh() })
  void refresh()

  return () => {
    closed = true
    unregister()
    options.onStatus?.({ status: 'closed', failedCount })
  }
}
