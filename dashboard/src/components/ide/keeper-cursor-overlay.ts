/**
 * Keeper Cursor Overlay — Multi-keeper observation layer
 * Enhanced with precise cursor positions from keeper activity
 */

import { html } from 'htm/preact'
import { signal } from '@preact/signals'

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
}

// ── Signals ──────────────────────────────────────────────────────

export const cursorOverlaySignal = signal<KeeperCursorOverlay>({
  cursors: new Map(),
  heatmap: new Map(),
  collisions: [],
  active_file: null,
})

// ── Keeper Color Mapping ─────────────────────────────────────────

const KEEPER_COLORS = [
  { cursor: '#FF6B6B', selection: 'rgba(255, 107, 107, 0.2)', name: 'Red' },
  { cursor: '#4ECDC4', selection: 'rgba(78, 205, 196, 0.2)', name: 'Teal' },
  { cursor: '#45B7D1', selection: 'rgba(69, 183, 209, 0.2)', name: 'Blue' },
  { cursor: '#96CEB4', selection: 'rgba(150, 206, 180, 0.2)', name: 'Green' },
  { cursor: '#FFEAA7', selection: 'rgba(255, 234, 167, 0.3)', name: 'Yellow' },
  { cursor: '#DDA0DD', selection: 'rgba(221, 160, 221, 0.2)', name: 'Plum' },
  { cursor: '#FFA07A', selection: 'rgba(255, 160, 122, 0.2)', name: 'Salmon' },
  { cursor: '#98FB98', selection: 'rgba(152, 251, 152, 0.2)', name: 'PaleGreen' },
]

export function getKeeperColor(keeperId: string, index?: number): { cursor: string; selection: string } {
  const idx = index ?? (keeperId.charCodeAt(0) + (keeperId.charCodeAt(1) || 0)) % KEEPER_COLORS.length
  return KEEPER_COLORS[idx] ?? { cursor: KEEPER_COLORS[0]!.cursor, selection: KEEPER_COLORS[0]!.selection }
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
  color: { cursor: string; selection: string }
  onJump?: (keeperId: string, line: number) => void
}

export function KeeperCursorWidget({ cursor, color, onJump }: KeeperCursorWidgetProps) {
  const label = cursor.tool_name 
    ? `${cursor.keeper_id} (${cursor.tool_name})`
    : cursor.keeper_id
  
  return html`
    <div
      class="keeper-cursor-widget"
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
          color: '#fff',
          fontSize: '10px',
          fontWeight: '600',
          borderRadius: '3px',
          boxShadow: '0 1px 3px rgba(0,0,0,0.2)',
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
    <div class="collision-warnings" style=${{
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
    <div class="heatmap-ruler" style=${{
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
              background: `rgba(255, 107, 107, ${opacity})`,
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
    <div class="active-file-indicator" style=${{
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

export function connectKeeperCursorStream(
  baseUrl: string,
  onUpdate: (overlay: KeeperCursorOverlay) => void,
): () => void {
  const eventSource = new EventSource(`${baseUrl}/api/v1/ide/presence/stream`)
  
  eventSource.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data)
      const entries = data.entries || []
      
      const cursors = new Map<string, KeeperCursor>()
      let activeFilePath: string | null = null
      
      for (const entry of entries) {
        // Extract file path from workspace_label or branch info
        const filePath = entry.file_path || ''
        if (filePath && !activeFilePath) {
          activeFilePath = filePath
        }
        
        cursors.set(entry.keeper_id, {
          keeper_id: entry.keeper_id,
          file_path: filePath,
          line: entry.line || 0,
          column: entry.column || 0,
          focus_mode: entry.focus_mode || 'reading',
          last_update: entry.last_seen_ms,
          tool_name: entry.tool_name,
          turn: entry.turn,
        })
      }
      
      const collisionArray = detectCollisions(cursors.values())
      const heatmapMap = calculateHeatmap(cursors.values())
      
      onUpdate({ 
        cursors, 
        heatmap: heatmapMap, 
        collisions: collisionArray,
        active_file: activeFilePath,
      })
    } catch (err) {
      console.error('Keeper cursor stream parse error:', err)
    }
  }
  
  eventSource.onerror = (err) => {
    console.error('Keeper cursor stream error:', err)
    // Reconnect after delay
    setTimeout(() => {
      eventSource.close()
      connectKeeperCursorStream(baseUrl, onUpdate)
    }, 3000)
  }
  
  return () => {
    eventSource.close()
  }
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
