/**
 * Keeper Cursor CM6 Extension — renders multi-keeper cursor positions
 * as CodeMirror decorations (line highlights + cursor labels + collision warnings).
 *
 * Bridges the Preact signal layer (cursorOverlaySignal) into CM6's
 * decoration system via a ViewPlugin.
 */

import {
  EditorView,
  ViewPlugin,
  Decoration,
  type DecorationSet,
  type ViewUpdate,
  WidgetType,
} from '@codemirror/view'
import { StateField, StateEffect, type Range } from '@codemirror/state'
import {
  cursorOverlaySignal,
  getKeeperColor,
  type KeeperCursorOverlay,
  type KeeperCursor,
  type KeeperCursorColor,
} from './keeper-cursor-overlay'

// ── Types ─────────────────────────────────────────────────────────

interface CollisionEntry {
  readonly line: number
  readonly keeperIds: ReadonlyArray<string>
}

const setCollisionData = StateEffect.define<ReadonlyArray<CollisionEntry>>()

// ── Cursor Label Widget ───────────────────────────────────────────

class KeeperCursorLabelWidget extends WidgetType {
  constructor(
    private readonly keeperId: string,
    private readonly toolName: string | undefined,
    private readonly focusMode: string,
    private readonly color: KeeperCursorColor,
  ) { super() }

  toDOM(): HTMLElement {
    const label = this.toolName
      ? `${this.keeperId} (${this.toolName})`
      : this.keeperId

    const container = document.createElement('span')
    container.className = 'cm-keeper-cursor-label'
    container.style.cssText =
      `display:inline-flex;align-items:center;gap:3px;` +
      `padding:1px 5px;margin-left:4px;` +
      `background:${this.color.cursor};color:${this.color.text};` +
      `font-size:10px;font-weight:600;border-radius:3px;` +
      `box-shadow:${this.color.shadow};` +
      `pointer-events:none;user-select:none;line-height:1.4;`
    container.textContent = label

    const mode = document.createElement('span')
    mode.style.cssText = 'opacity:0.75;margin-left:2px;'
    mode.textContent = this.focusMode
    container.appendChild(mode)

    return container
  }

  eq(other: KeeperCursorLabelWidget): boolean {
    return this.keeperId === other.keeperId
      && this.toolName === other.toolName
      && this.focusMode === other.focusMode
  }
}

// ── Collision Warning Widget ──────────────────────────────────────

class CollisionWarningWidget extends WidgetType {
  constructor(
    private readonly line: number,
    private readonly keeperIds: ReadonlyArray<string>,
  ) { super() }

  toDOM(): HTMLElement {
    const el = document.createElement('div')
    el.className = 'cm-collision-warning'

    el.style.cssText =
      `display:flex;align-items:center;gap:4px;` +
      `padding:2px 6px;margin-left:8px;` +
      `background:rgb(var(--color-accent-glow) / 0.08);` +
      `border:1px solid rgb(var(--color-accent-glow) / 0.2);` +
      `border-radius:3px;font-size:10px;` +
      `pointer-events:none;user-select:none;white-space:nowrap;`

    const icon = document.createElement('span')
    icon.textContent = '↔'
    icon.style.cssText = 'font-weight:700;color:var(--color-fg-warning)'
    el.appendChild(icon)

    const text = document.createElement('span')
    text.textContent = `${this.keeperIds.length} keepers: ${this.keeperIds.join(', ')}`
    text.style.cssText = 'color:var(--color-fg-muted)'
    el.appendChild(text)

    return el
  }

  eq(other: CollisionWarningWidget): boolean {
    return this.line === other.line
      && this.keeperIds.length === other.keeperIds.length
      && this.keeperIds.every((id, i) => id === other.keeperIds[i])
  }
}

// ── Decoration Builders ───────────────────────────────────────────

function buildLineHighlight(color: string): Decoration {
  return Decoration.line({
    attributes: { style: `background:${color}` },
  })
}

function buildCursorLabel(cursor: KeeperCursor, color: KeeperCursorColor): Decoration {
  return Decoration.widget({
    widget: new KeeperCursorLabelWidget(
      cursor.keeper_id,
      cursor.tool_name,
      cursor.focus_mode,
      color,
    ),
    side: 1,
  })
}

function buildCollisionWarning(collision: { line: number; keeper_ids: string[] }): Decoration {
  return Decoration.widget({
    widget: new CollisionWarningWidget(
      collision.line,
      collision.keeper_ids,
    ),
    side: -1,
  })
}

// ── Collision State Field ─────────────────────────────────────────

const collisionField = StateField.define<ReadonlyArray<CollisionEntry>>({
  create() { return [] },
  update(state, tr) {
    for (const eff of tr.effects) {
      if (eff.is(setCollisionData)) return eff.value
    }
    return state
  },
})

// ── ViewPlugin ────────────────────────────────────────────────────

const keeperCursorPlugin = ViewPlugin.fromClass(
  class {
    private decorations: DecorationSet = Decoration.none
    private unsubscribe: (() => void) | null = null
    private lastOverlaySnapshot: string = ''

    constructor(private readonly view: EditorView) {
      this.subscribeToSignal()
    }

    private subscribeToSignal(): void {
      // Poll the signal on every CM update (scheduler-driven).
      // We diff by serializing the overlay state to avoid
      // rebuilding decorations when nothing changed.
    }

    update(update: ViewUpdate): void {
      if (!update.docChanged && !update.viewportChanged) {
        // Still check signal changes
        this.rebuildFromSignal()
        return
      }
      this.rebuildFromSignal()
    }

    private rebuildFromSignal(): void {
      const overlay = cursorOverlaySignal.value
      const snapshot = this.serializeOverlay(overlay)

      if (snapshot === this.lastOverlaySnapshot) return
      this.lastOverlaySnapshot = snapshot

      const decorations: Range<Decoration>[] = []
      const collisionEffects: CollisionEntry[] = []

      const doc = this.view.state.doc
      const lineCount = doc.lines

      // Build per-keeper decorations
      for (const [keeperId, cursor] of overlay.cursors) {
        if (cursor.line < 1 || cursor.line > lineCount) continue

        const color = getKeeperColor(keeperId)

        // Selection highlight (line decoration)
        const startLine = cursor.line
        const endLine = cursor.selection_end?.line ?? cursor.line
        for (let ln = startLine; ln <= Math.min(endLine, lineCount); ln++) {
          const pos = doc.line(ln).from
          decorations.push(buildLineHighlight(color.selection).range(pos))
        }

        // Cursor label (widget at cursor line)
        const cursorLinePos = doc.line(cursor.line).from
        decorations.push(buildCursorLabel(cursor, color).range(cursorLinePos))
      }

      // Collision warnings
      for (const collision of overlay.collisions) {
        if (collision.line < 1 || collision.line > lineCount) continue

        const pos = doc.line(collision.line).from
        decorations.push(buildCollisionWarning(collision).range(pos))

        collisionEffects.push({
          line: collision.line,
          keeperIds: collision.keeper_ids,
        })
      }

      // Sort decorations by position
      decorations.sort((a, b) => a.from - b.from)

      this.decorations = Decoration.set(decorations, true)

      // Dispatch collision data for external consumers
      if (collisionEffects.length > 0) {
        this.view.dispatch({
          effects: [setCollisionData.of(collisionEffects)],
        })
      }
    }

    private serializeOverlay(overlay: KeeperCursorOverlay): string {
      const parts: string[] = []
      for (const [id, c] of overlay.cursors) {
        parts.push(`${id}:${c.line}:${c.focus_mode}`)
      }
      for (const col of overlay.collisions) {
        parts.push(`c:${col.line}:${col.keeper_ids.join(',')}`)
      }
      return parts.join('|')
    }

    destroy(): void {
      if (this.unsubscribe) {
        this.unsubscribe()
        this.unsubscribe = null
      }
    }

    get decos(): DecorationSet {
      return this.decorations
    }
  },
  {
    decorations: (plugin) => plugin.decos,
  },
)

// ── Theme ─────────────────────────────────────────────────────────

const keeperCursorTheme = EditorView.theme({
  '.cm-keeper-cursor-label': {
    position: 'relative',
    zIndex: '5',
  },
  '.cm-collision-warning': {
    position: 'relative',
    zIndex: '5',
  },
})

// ── Public API ────────────────────────────────────────────────────

export function keeperCursorExtension(): import('@codemirror/state').Extension {
  return [
    collisionField,
    keeperCursorPlugin,
    keeperCursorTheme,
  ]
}

export function getCollisions(view: EditorView): ReadonlyArray<CollisionEntry> {
  return view.state.field(collisionField)
}
