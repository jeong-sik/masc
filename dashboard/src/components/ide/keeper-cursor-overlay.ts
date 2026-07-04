/**
 * Keeper Cursor Overlay — Multi-keeper observation layer
 * Enhanced with precise cursor positions from keeper activity
 */

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { dashboardBearerToken } from '../../api/core'
import { createSseTransport } from '../../transports/sse-transport'

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
    risk_level: 'low' | 'medium' | 'high'
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
  readonly repoId?: string | null
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
  risk_level: 'low' | 'medium' | 'high'
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
  
  const collisions: Array<{ line: number; keeper_ids: string[]; risk_level: 'low' | 'medium' | 'high' }> = []
  
  lineToKeepers.forEach((keepers, line) => {
    if (keepers.length > 1) {
      const risk: 'low' | 'medium' | 'high' =
        keepers.length >= 3 ? 'high' : keepers.length === 2 ? 'medium' : 'low'
      collisions.push({ line, keeper_ids: keepers, risk_level: risk })
    }
  })
  
  return collisions.sort((a, b) => {
    if (b.risk_level === 'high' && a.risk_level !== 'high') return 1
    if (a.risk_level === 'high' && b.risk_level !== 'high') return -1
    return b.keeper_ids.length - a.keeper_ids.length
  })
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

// ── Components ───────────────────────────────────────────────────

interface KeeperCursorWidgetProps {
  cursor: KeeperCursor
  color: KeeperCursorColor
  onJump?: (keeperId: string, line: number) => void
}

export function KeeperCursorWidget({ cursor, color, onJump }: KeeperCursorWidgetProps) {
  const label = cursor.tool_name 
    ? `${cursor.keeper_id} (${cursor.tool_name})`
    : cursor.keeper_id
  
  return html`
    <div
      class="keeper-cursor-widget v2-ide-detail"
      style=${{
        position: 'absolute',
        left: 0,
        top: `${cursor.line * 24}px`,
        zIndex: 10,
        pointerEvents: 'none',
      }}
    >
      ${cursor.selection_end && html`
        <div
          class="keeper-selection"
          style=${{
            position: 'absolute',
            left: 0,
            right: 0,
            top: 0,
            bottom: `${(cursor.selection_end.line - cursor.line) * 24}px`,
            background: color.selection,
            pointerEvents: 'auto',
            cursor: 'pointer',
          }}
          onClick=${() => onJump?.(cursor.keeper_id, cursor.line)}
        />
      `}
      <div
        class="keeper-cursor-label"
        style=${{
          display: 'inline-flex',
          alignItems: 'center',
          gap: '4px',
          padding: '2px 6px',
          background: color.cursor,
          color: color.text,
          fontSize: '10px',
          fontWeight: '600',
          borderRadius: '3px',
          boxShadow: color.shadow,
        }}
      >
        <span>${label}</span>
        <span style=${{ opacity: 0.8 }}>{cursor.focus_mode}</span>
      </div>
    </div>
  `
}

interface CollisionWarningProps {
  collisions: Array<{ line: number; keeper_ids: string[]; risk_level: 'low' | 'medium' | 'high' }>
}

export function CollisionWarning({ collisions }: CollisionWarningProps) {
  if (collisions.length === 0) return null
  
  const highRisk = collisions.filter(c => c.risk_level === 'high')
  const mediumRisk = collisions.filter(c => c.risk_level === 'medium')
  
  return html`
    <div class="collision-warnings v2-ide-panel" style=${{
      padding: '8px 12px',
      background: 'var(--color-bg-warning)',
      borderBottom: '1px solid var(--color-border-warning)',
    }}>
      <div style=${{ fontWeight: '600', marginBottom: '4px' }}>
        ⚠️ Multi-Keeper Collision Detection
      </div>
      ${highRisk.length > 0 && html`
        <div style=${{ color: 'var(--color-fg-danger)', fontSize: '12px' }}>
          High Risk (${highRisk.length} lines): ${highRisk.map(c => `L${c.line}`).join(', ')}
        </div>
      `}
      ${mediumRisk.length > 0 && html`
        <div style=${{ color: 'var(--color-fg-warning)', fontSize: '12px' }}>
          Medium Risk (${mediumRisk.length} lines): ${mediumRisk.map(c => `L${c.line}`).join(', ')}
        </div>
      `}
    </div>
  `
}

interface HeatmapRulerProps {
  heatmap: Map<number, number>
  totalLines: number
}

export function HeatmapRuler({ heatmap, totalLines }: HeatmapRulerProps) {
  const maxActivity = Math.max(1, ...heatmap.values())
  
  return html`
    <div class="heatmap-ruler v2-ide-panel" style=${{
      width: '4px',
      background: 'var(--color-bg-surface)',
      borderLeft: '1px solid var(--color-border-default)',
    }}>
      ${Array.from({ length: Math.min(totalLines, 100) }, (_, i) => {
        const line = Math.floor(i * totalLines / 100)
        const activity = heatmap.get(line) || 0
        const intensity = activity / maxActivity
        const opacity = 0.1 + (intensity * 0.9)
        
        return html`
          <div
            key=${line}
            style=${{
              height: '2px',
              background: `rgb(var(--color-accent-glow) / ${opacity})`,
              marginBottom: '4px',
            }}
            title=${`Line ${line}: ${activity} active keepers`}
          />
        `
      })}
    </div>
  `
}

interface ActiveFileIndicatorProps {
  activeFile: string | null
  keeperCount: number
}

export function ActiveFileIndicator({ activeFile, keeperCount }: ActiveFileIndicatorProps) {
  if (!activeFile) return null
  
  return html`
    <div class="active-file-indicator v2-ide-panel" style=${{
      padding: '6px 12px',
      background: 'var(--color-bg-muted)',
      borderBottom: '1px solid var(--color-border-default)',
      fontSize: '12px',
      display: 'flex',
      alignItems: 'center',
      gap: '8px',
    }}>
      <span style=${{ fontWeight: '600' }}>📄</span>
      <span style=${{ fontFamily: 'var(--font-mono)' }}>{activeFile}</span>
      <span style=${{ marginLeft: 'auto', color: 'var(--color-fg-muted)' }}>
        ${keeperCount} keeper${keeperCount !== 1 ? 's' : ''} active
      </span>
    </div>
  `
}

// ── SSE Stream Integration ───────────────────────────────────────

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

export function connectKeeperCursorStream(
  baseUrl: string,
  onUpdate: (overlay: KeeperCursorOverlay) => void,
  options: KeeperCursorStreamOptions = {},
): () => void {
  let failedCount = 0
  options.onStatus?.({ status: 'connecting', failedCount })
  if (typeof EventSource === 'undefined') {
    failedCount = 1
    options.onStatus?.({
      status: 'degraded',
      failedCount,
      lastErrorMs: Date.now(),
      error: 'EventSource unavailable',
    })
    return () => {
      options.onStatus?.({ status: 'closed', failedCount })
    }
  }

  const transport = createSseTransport(buildKeeperCursorStreamUrl(baseUrl, options.repoId))
  const unsubscribe = transport.subscribe((event) => {
    if (event.type === 'open') {
      failedCount = 0
      options.onStatus?.({ status: 'live', failedCount, lastOpenMs: Date.now() })
      return
    }
    if (event.type === 'message') {
      onUpdate(normalizeKeeperCursorSnapshot(event.data))
      return
    }
    if (event.type === 'error') {
      failedCount += 1
      options.onStatus?.({
        status: 'degraded',
        failedCount,
        lastErrorMs: Date.now(),
        error: event.error.message,
      })
      console.error('Keeper cursor stream error:', event.error)
      return
    }
    if (event.type === 'close') {
      options.onStatus?.({ status: 'closed', failedCount })
    }
  })
  transport.connect()

  return () => {
    transport.disconnect()
    unsubscribe()
  }
}

export function buildKeeperCursorStreamUrl(baseUrl: string, repoId?: string | null): string {
  const base = baseUrl.trim().replace(/\/+$/, '')
  const endpoint = `${base}/api/v1/ide/cursors/stream`
  const params = new URLSearchParams()
  const trimmedRepoId = repoId?.trim()
  const token = dashboardBearerToken()
  if (trimmedRepoId) params.set('repo_id', trimmedRepoId)
  if (token) params.set('token', token)
  const query = params.toString()
  return query ? `${endpoint}?${query}` : endpoint
}

// ── Helper to update cursor from tool call ───────────────────────

export function updateCursorFromToolCall(
  overlay: KeeperCursorOverlay,
  keeperId: string,
  filePath: string,
  lineStart: number,
  lineEnd: number,
  toolName: string,
  turn: number,
): KeeperCursorOverlay {
  const now = Date.now()
  
  const updated: KeeperCursor = {
    keeper_id: keeperId,
    file_path: filePath,
    line: lineStart,
    column: 0,
    selection_end: lineEnd !== lineStart ? { line: lineEnd, column: 0 } : undefined,
    focus_mode: 'editing',
    last_update: now,
    tool_name: toolName,
    turn,
  }
  
  const newCursors = new Map(overlay.cursors)
  newCursors.set(keeperId, updated)
  
  return {
    ...overlay,
    cursors: newCursors,
    heatmap: calculateHeatmap(newCursors.values()),
    collisions: detectCollisions(newCursors.values()),
    active_file: filePath,
  }
}
